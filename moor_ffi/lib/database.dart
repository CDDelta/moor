/// Exports the low-level [Database] class to run operations on a sqlite
/// database via `dart:ffi`.
@Deprecated('Consider migrating to package:sqlite3/sqlite3.dart')
library database;

import 'package:moor_ffi/src/bindings/types.dart';

export 'src/api/result.dart';
export 'src/bindings/types.dart' hide Database, Statement;
export 'src/impl/database.dart'
    show SqliteException, Database, PreparedStatement;
