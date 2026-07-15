#include "HostwrightSQLiteSupport.h"

int hostwright_sqlite_set_db_config(
    sqlite3 *database,
    int option,
    int value,
    int *effective_value
) {
    return sqlite3_db_config(database, option, value, effective_value);
}
