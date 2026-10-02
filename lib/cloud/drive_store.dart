import 'dart:async';
import 'dart:io';

import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;

/// Why a book file wasn't uploaded.
enum UploadSkip { driveLow, overLimit }

/// Book files and covers in the hidden app folder of the user's own Google Drive, named by
/// the book's fingerprint: `<id>.epub`, `<id>.jpg`. They count against the user's Drive
/// quota, so nothing is uploaded when Drive has under 1 GB free, or past the user's limit.
class DriveStore {
  DriveStore(http.Client client) : _api = drive.DriveApi(client);

  final drive.DriveApi _api;

  static const minFreeBytes = 1024 * 1024 * 1024;

  /// Space left in the user's Drive, or null if Drive has no limit.
  Future<int?> freeBytes() async {
    final about = await _api.about.get($fields: 'storageQuota');
    final quota = about.storageQuota;
    final limit = int.tryParse(quota?.limit ?? '');
    final usage = int.tryParse(quota?.usage ?? '') ?? 0;
    return limit == null ? null : limit - usage;
  }

  /// Bytes the app's files take in Drive.
  Future<int> usedByApp() async {
    var total = 0;
    String? page;
    do {
      final list = await _api.files.list(
        spaces: 'appDataFolder',
        $fields: 'nextPageToken, files(size)',
        pageSize: 1000,
        pageToken: page,
      );
      for (final f in list.files ?? const <drive.File>[]) {
        total += int.tryParse(f.size ?? '') ?? 0;
      }
      page = list.nextPageToken;
    } while (page != null);
    return total;
  }

  /// Checks a [bytes]-sized upload against Drive's free space and the user's [limitBytes].
  Future<UploadSkip?> canUpload(int bytes, {int? limitBytes}) async {
    final free = await freeBytes();
    if (free != null && free - bytes < minFreeBytes) return UploadSkip.driveLow;
    if (limitBytes != null && await usedByApp() + bytes > limitBytes) return UploadSkip.overLimit;
    return null;
  }

  /// Uploads [file] as [name], resumably; returns its Drive file id. A file already there
  /// under that name is reused, so a book is never stored twice.
  Future<String> upload(File file, String name, String mimeType) async {
    final existing = await find(name);
    if (existing != null) return existing;
    final created = await _api.files.create(
      drive.File(name: name, parents: ['appDataFolder']),
      uploadMedia: drive.Media(file.openRead(), await file.length(), contentType: mimeType),
      uploadOptions: drive.ResumableUploadOptions(),
      $fields: 'id',
    );
    return created.id!;
  }

  Future<String?> find(String name) async {
    final list = await _api.files.list(
      spaces: 'appDataFolder',
      q: "name = '$name' and trashed = false",
      $fields: 'files(id)',
      pageSize: 1,
    );
    return list.files?.firstOrNull?.id;
  }

  /// Downloads a file to [target], reporting progress from 0 to 1.
  Future<void> download(
    String fileId,
    File target, {
    int? expectedBytes,
    void Function(double)? onProgress,
  }) async {
    final media = await _api.files.get(
      fileId,
      downloadOptions: drive.DownloadOptions.fullMedia,
    ) as drive.Media;
    final total = media.length ?? expectedBytes;
    final partial = File('${target.path}.part');
    await partial.parent.create(recursive: true);
    final sink = partial.openWrite();
    var received = 0;
    await for (final chunk in media.stream) {
      sink.add(chunk);
      received += chunk.length;
      if (total != null && total > 0) onProgress?.call(received / total);
    }
    await sink.close();
    await partial.rename(target.path);
  }

  Future<void> delete(String fileId) => _api.files.delete(fileId);

  /// Removes everything the app keeps in Drive.
  Future<void> deleteAll() async {
    String? page;
    do {
      final list = await _api.files.list(
        spaces: 'appDataFolder',
        $fields: 'nextPageToken, files(id)',
        pageSize: 1000,
        pageToken: page,
      );
      for (final f in list.files ?? const <drive.File>[]) {
        await _api.files.delete(f.id!);
      }
      page = list.nextPageToken;
    } while (page != null);
  }
}
