#ifndef FileExplorer_ArchiveBridge_h
#define FileExplorer_ArchiveBridge_h
#include <sys/types.h>
#include <stdint.h>
#include <stddef.h>

// Minimal public C ABI used by this application. macOS SDKs ship libarchive
// but do not consistently ship its headers. Keep these declarations aligned
// with Apple's published libarchive 3.x interface:
// https://github.com/apple-oss-distributions/libarchive/blob/main/libarchive/libarchive/archive.h
// https://github.com/apple-oss-distributions/libarchive/blob/main/libarchive/libarchive/archive_entry.h
struct archive;
struct archive_entry;
struct archive *archive_read_new(void);
int archive_read_support_filter_all(struct archive *);
int archive_read_support_format_all(struct archive *);
int archive_read_open_filename(struct archive *, const char *, size_t);
int archive_read_next_header(struct archive *, struct archive_entry **);
const char *archive_entry_pathname(struct archive_entry *);
mode_t archive_entry_filetype(struct archive_entry *);
const char *archive_entry_hardlink(struct archive_entry *);
const char *archive_entry_symlink(struct archive_entry *);
int64_t archive_entry_size(struct archive_entry *);
ssize_t archive_read_data(struct archive *, void *, size_t);
int archive_read_free(struct archive *);
const char *archive_error_string(struct archive *);
#endif
