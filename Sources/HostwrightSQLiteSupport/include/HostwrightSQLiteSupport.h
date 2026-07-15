#ifndef HOSTWRIGHT_SQLITE_SUPPORT_H
#define HOSTWRIGHT_SQLITE_SUPPORT_H

#include <sqlite3.h>

int hostwright_sqlite_set_db_config(
    sqlite3 *database,
    int option,
    int value,
    int *effective_value
);

#endif
