using Gee;

namespace GDriveSync {

    public class DriveFile : File {

        public string downloadUrl { get; set; }
        public long modifiedDate { get; set; }
        public string MD5 { get; set; }

        public HashMap<string, DriveFile> children = new HashMap<string, DriveFile>();

        DriveFile() {
        }

        public DriveFile.as_root() {
            isRoot = true;
            isFolder = true;
            path = "";
        }

        public static void sync(DriveFile root) {
            fetchLocalMeta(root);
            // TODO: add local metadata (
            // LocalDB.fetchMeta(this);
            fetchRemoteMeta(root);
            doSync(root);
        }

        static void doSync(DriveFile file) {

            // TODO: need to rethink this logic.. to make it as small and sane as possible

            bool folderDeleted = false;
            
            if (file.isFolder) {
                if (file.localExists) {
                    if (!file.remoteExists) file.createRemoteDir();
                } else if (file.wasSynced) {
                    if (file.remoteExists) {
                        file.deleteRemote();
                        folderDeleted = true;
                    }
                } else {
                    if (file.remoteExists) file.createDir();
                }
            } else {
                if (file.remoteExists) {
                    //if (!file.wasSynced && file.downloadUrl != null) {
                        // file exists remotely and has not been synced before
                        message(file.MD5);
                        message(file.localMD5);
                        if (file.MD5 != file.localMD5) {
                            message("%ld", file.modifiedDate);
                            message("%ld", file.localModifiedDate);
                            
                            if (!file.localExists) {
                                file.download();
                            } else {
                                if (file.modifiedDate >= file.localModifiedDate) {
                                    file.delete();
                                    file.download();
                                } else {
                                    file.update();
                                }
                            }
                        }
                    //} else if (file.wasSynced && !file.localExists) {
                        // file exists remotely, has been synced before but no longer exists locally, delete it remotely
                        //file.deleteRemote();
                    //}
                } else {
                    if (file.wasSynced) {
                        // file exists locally and was synced with remote but it longer exists remotely, delete it locally
                        file.delete();
                    } else {
                        // file exist locally and hasn't been synced before and does not exist remotely, upload
                        file.upload();
                    }
                }
            }

            if (!folderDeleted) {
                foreach (var child in file.children.values) {
                    doSync(child);
                }
            }
        }

        public static void fetchLocalMeta(DriveFile folder) {
            folder.createDir();

            var dir = Dir.open(folder.getAbsPath());
            string? name = null;
            while ((name = dir.read_name ()) != null) {
                var relativePath = Path.build_filename(folder.path, name);

                var file = new DriveFile();
                file.path = relativePath;
                file.title = name;
                file.localExists = true;

                FileInfo info = file.queryInfo();
                var type = info.get_file_type();
                file.localFileSize = info.get_size();
                file.localModifiedDate = info.get_modification_time().tv_sec;
                if (type == FileType.DIRECTORY) {
                    file.isFolder = true;
                    fetchLocalMeta(file);
                } else if (type == FileType.REGULAR) {
                    file.isFolder = false;
                    file.localMD5 = file.calcLocalMD5();
                }
                folder.children.set(name, file);
            }
        }

        public static void fetchRemoteMeta(DriveFile root) {            
            message("Retrieve root folder metadata from Google Drive");
            fetchRootFolderMeta(root);
            message("Retrieve all folders metadata from Google Drive");
            getItemsMeta(root);
        }

        static Json.Object requestJson(string url) {
            Soup.Session session = new Soup.Session();
            Json.Parser parser = new Json.Parser();
            var message = new Soup.Message("GET", url);
            session.send_message(message);
            var data = (string) message.response_body.flatten().data;
            try {
                parser.load_from_data (data, -1);
            } catch (Error e) {
                critical(e.message);
            }
            return parser.get_root().get_object();
        }

        static DriveFile parseItem(Json.Node node) {
            var object = node.get_object();
            var file = new DriveFile();

            // NOTE: ignore items with other than 1 parent
            var parents = object.get_array_member("parents");
            if (parents.get_length() != 1) return null;

            var owners = object.get_array_member("owners");
            var isOwned = false;
            foreach (var owner in owners.get_elements()) {
                if (owner.get_object().get_boolean_member("isAuthenticatedUser")) isOwned = true;
            }
            if (!isOwned && !notowned) return null;

            file.id = object.get_string_member("id");
            file.remoteExists = true;
            file.title = object.get_string_member("title");
            if (object.has_member("modifiedDate")) {
                var modifiedDate = TimeVal();
                modifiedDate.from_iso8601(object.get_string_member("modifiedDate"));
                file.modifiedDate = modifiedDate.tv_sec;
            }
            //file.fileSize = object.has_member("fileSize") ? (int64) object.get_int_member("fileSize") : 0;
            file.MD5 = object.has_member("md5Checksum") ? object.get_string_member("md5Checksum") : null;
            file.downloadUrl = object.has_member("downloadUrl") ? object.get_string_member("downloadUrl") : null;

            var mimeType = object.get_string_member("mimeType");
            file.isFolder = mimeType == "application/vnd.google-apps.folder";

            return file;
        }

        static void getItemsMeta(DriveFile folder, string? nextLink = null) {
            message("Requesting metadata for " + folder.title);

            var url = nextLink != null ? nextLink : @"https://www.googleapis.com/drive/v2/files?q=trashed+%3D+false+and+'$(folder.id)'+in+parents";
            url += @"&access_token=$(AuthInfo.access_token)";
            var json = requestJson(url);
            var items = json.get_array_member("items");

            foreach (var node in items.get_elements()) {
                var file = parseItem(node);
                if (file != null) {
                    file.path = folder.path + file.title;
                    if (folder.children.has_key(file.title)) {
                        var existing = folder.children.get(file.title);
                        existing.id = file.id;
                        existing.remoteExists = file.remoteExists;
                        existing.modifiedDate = file.modifiedDate;
                        existing.MD5 = file.MD5;
                        existing.downloadUrl = file.downloadUrl;
                        file = existing;
                    } else {
                        folder.children.set(file.title, file);
                    }
                    if (file.isFolder) {
                        file.path = file.path + "/";
                        getItemsMeta(file);
                    }
                }
            }

            var next = json.has_member("nextLink") && !json.get_null_member("nextLink") ? json.get_string_member("nextLink") : null;
            if (next != null) getItemsMeta(folder, next);
        }

        static void fetchRootFolderMeta(DriveFile root) {
            var url = "https://www.googleapis.com/drive/v2/about?";
            url += @"access_token=$(AuthInfo.access_token)";
            var json = requestJson(url);
            var rootFolderId = json.get_string_member("rootFolderId");
            root.id = rootFolderId;
        }

        public void download() {
            message("Downloading " + path);

            var url_auth = downloadUrl + @"&access_token=$(AuthInfo.access_token)";

            Soup.Session session = new Soup.Session();
            var message = new Soup.Message("GET", url_auth);
            session.send_message(message);
            var data = message.response_body.flatten().data;

            try {
                var file = getLocalFile();
                var os = file.create(FileCreateFlags.PRIVATE | FileCreateFlags.REPLACE_DESTINATION);
                size_t bytes_written;
                os.write_all(data, out bytes_written);
                os.close();
                file.set_attribute_uint64(FileAttribute.TIME_MODIFIED, modifiedDate, 0);
            } catch (Error e) {
                critical(e.message);
            }
        }

        public void upload() {
            message("Uploading " + path);

            var url = "https://www.googleapis.com/upload/drive/v2/files?";
            url += url + @"&uploadType=resumable&access_token=$(AuthInfo.access_token)";

            Soup.Session session = new Soup.Session();
            var msg = new Soup.Message("POST", url);

            msg.request_headers.append("X-Upload-Content-Type", "image/png");
            msg.request_headers.append("X-Upload-Content-Length", localFileSize.to_string());
            msg.request_headers.append("Content-Type", "application/json; charset=UTF-8");

            var generator = new Json.Generator();
            var root = new Json.Node(Json.NodeType.OBJECT);
            var object = new Json.Object();
            root.set_object(object);
            generator.set_root(root);
            object.set_string_member("title", title);
            var json = generator.to_data(null);

            msg.request_body.append(Soup.MemoryUse.COPY, json.data);
            session.send_message(msg);

            message("sending message");
            session.send_message(msg);

            var location = msg.response_headers.get("Location");

            msg = new Soup.Message("PUT", location);
            msg.request_headers.append("Authorization", @"Bearer $(AuthInfo.access_token)");
            msg.request_headers.append("Content-Type", "image/png");

            var file = getLocalFile();
            var stream = file.read();
	        uint8 fbuf[1024];
	        size_t size;

	        while ((size = stream.read (fbuf)) > 0) {
                msg.request_body.append(Soup.MemoryUse.COPY, fbuf);
	        }
            msg.request_body.flatten();
            msg.request_headers.append("Content-Length", localFileSize.to_string());
            session.send_message(msg);
            var data = (string) msg.response_body.flatten().data;
            message(data);
        }

        public void update() {
            message("Uploading update " + path);
        }

        public void deleteRemote() {
            message("Deleting " + path);
        }

        public void createRemoteDir() {
            message("Create remote dir " + path);
        }
    }

}