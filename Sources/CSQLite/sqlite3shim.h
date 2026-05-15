#if __has_include(<sqlite3.h>)
#include <sqlite3.h>
#elif __has_include(<SQLite3/sqlite3.h>)
#include <SQLite3/sqlite3.h>
#else
#error "sqlite3.h not found"
#endif
