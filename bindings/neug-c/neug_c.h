/* A C interface to NeuG, the embedded graph database, which has only a C++ one.
 *
 * It wraps NeugDB, Connection and QueryResult and nothing else, and hides the protobuf,
 * abseil, glog and rapidjson that the headers of NeuG are made of: a program that includes
 * this file needs none of them. The library that implements it, libneug_c.so, exports the
 * functions below and no other symbol.
 *
 * OWNERSHIP. A handle is freed by its *_free function (NULL is accepted). Every other pointer
 * that a function returns is BORROWED: the text of an error or of a column name lives until the
 * error or the result is freed, the pointer from neug_result_get_string until the next call on
 * that result.
 *
 * THREADS. neug_db_open, neug_db_close and neug_db_free are serialized by a mutex of the
 * library (NeuG initializes a process-wide parser). neug_conn_open may be called from several
 * threads on one database. A connection and a result are used by one thread at a time (they
 * may move between threads). A result owns its data and may outlive its connection and its
 * database. Close a database only when no call on it is running.
 *
 * ERRORS. A function returns a status. NEUG_OK (0) is success. NEUG_NULL (1) is not an error:
 * the cell read is NULL and the output is untouched. Any other value is an error, and if the
 * `err` argument is not NULL, *err is set to a new neug_error that the caller frees. Codes from
 * 1001 on are those of NeuG (neug::interactive::Code); codes from 10001 are the library's own.
 * C++ exceptions never cross this interface. What cannot be caught is a failed CHECK or
 * LOG(FATAL) inside the engine, which aborts the process: NeuG has about 130 of them, and a
 * query that reaches one (a shortestPath over several labels, a MERGE of an unknown label)
 * ends the program. A program that cannot afford that runs the engine in a process of its own.
 */
#ifndef NEUG_C_H
#define NEUG_C_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define NEUG_C_ABI_VERSION 1

#if defined(__GNUC__)
#define NEUG_C_API __attribute__((visibility("default")))
#else
#define NEUG_C_API
#endif

typedef struct neug_db neug_db;
typedef struct neug_conn neug_conn;
typedef struct neug_result neug_result;
typedef struct neug_error neug_error;

enum {
  NEUG_OK = 0,
  NEUG_NULL = 1,
  NEUG_E_NULL_ARGUMENT = 10001, /* a required pointer was NULL */
  NEUG_E_NO_ROW = 10002,        /* the cursor of the result is not on a row */
  NEUG_E_COLUMN = 10003,        /* a column index out of range */
  NEUG_E_TYPE = 10004,          /* the getter does not match the type of the column */
  NEUG_E_ABI = 10005,           /* the library is not the one this header is of */
  NEUG_E_EXCEPTION = 10006,     /* the engine threw: its text ends with the code of NeuG, "Error Code: 4001" */
  NEUG_E_PARAMETERS = 10007,    /* the parameters are not a JSON object */
  NEUG_E_OTHER = 10008          /* an exception that is not a std::exception */
};

typedef enum {
  NEUG_ACCESS_INFER = 0, /* let NeuG tell */
  NEUG_ACCESS_READ = 1,
  NEUG_ACCESS_INSERT = 2,
  NEUG_ACCESS_UPDATE = 3,
  NEUG_ACCESS_SCHEMA = 4
} neug_access;

/* The type of a column of a result: the numbers of the protobuf of NeuG's responses. Only the
 * scalar types can be read with a typed getter; the others (list, struct, interval, vertex,
 * edge, path) are read with neug_result_get_string. date and timestamp are the raw int64 of
 * the engine with neug_result_get_i64. */
typedef enum {
  NEUG_T_UNSET = 0,
  NEUG_T_INT32 = 1,
  NEUG_T_UINT32 = 2,
  NEUG_T_INT64 = 3,
  NEUG_T_UINT64 = 4,
  NEUG_T_FLOAT = 5,
  NEUG_T_DOUBLE = 6,
  NEUG_T_STRING = 7,
  NEUG_T_BOOL = 8,
  NEUG_T_TIMESTAMP = 10,
  NEUG_T_DATE = 11,
  NEUG_T_INTERVAL = 12,
  NEUG_T_LIST = 15,
  NEUG_T_STRUCT = 16,
  NEUG_T_VERTEX = 20,
  NEUG_T_EDGE = 21,
  NEUG_T_PATH = 22
} neug_type;

typedef struct {
  size_t struct_size;        /* sizeof(neug_open_options), set by neug_open_options_init */
  const char* path;          /* NULL or "" for a database in memory (a temporary directory) */
  int32_t max_threads;       /* 0: as many as the machine has */
  int32_t read_only;         /* 0: read and write, which allows ONE connection */
  int32_t checkpoint_on_close;
} neug_open_options;

/* The version of this interface the library implements, to compare with NEUG_C_ABI_VERSION,
 * and the version of NeuG it is built against ("0.3.0"). */
NEUG_C_API uint32_t neug_c_abi_version(void);
NEUG_C_API const char* neug_c_version(void);

NEUG_C_API void neug_open_options_init(neug_open_options* options);

NEUG_C_API int32_t neug_error_code(const neug_error* error);
NEUG_C_API const char* neug_error_message(const neug_error* error);
NEUG_C_API void neug_error_free(neug_error* error);

NEUG_C_API int32_t neug_db_open(const neug_open_options* options, neug_db** out,
                                neug_error** err);
NEUG_C_API int32_t neug_db_close(neug_db* db, neug_error** err);
NEUG_C_API void neug_db_free(neug_db* db);

/* A read-write database has one connection: a second neug_conn_open is an error until the first
 * is freed. */
NEUG_C_API int32_t neug_conn_open(neug_db* db, neug_conn** out, neug_error** err);
NEUG_C_API void neug_conn_free(neug_conn* conn);

/* `params_json` is NULL or a JSON object with the values of the $parameters of the query. A
 * value of the wrong type for its use is not checked by the engine. */
NEUG_C_API int32_t neug_conn_query(neug_conn* conn, const char* cypher, neug_access access,
                                   const char* params_json, neug_result** out,
                                   neug_error** err);

NEUG_C_API int32_t neug_conn_begin(neug_conn* conn, int32_t read_only, neug_error** err);
NEUG_C_API int32_t neug_conn_commit(neug_conn* conn, neug_error** err);
NEUG_C_API int32_t neug_conn_rollback(neug_conn* conn, neug_error** err);
NEUG_C_API int32_t neug_conn_in_transaction(const neug_conn* conn);

NEUG_C_API size_t neug_result_rows(const neug_result* result);
NEUG_C_API size_t neug_result_columns(const neug_result* result);
NEUG_C_API const char* neug_result_column_name(const neug_result* result, size_t column);
NEUG_C_API neug_type neug_result_column_type(const neug_result* result, size_t column);

/* The cursor starts ON the first row. The first call to neug_result_step stays there, and the
 * following ones move on; the return value is 1 while the cursor is on a row and 0 at the end:
 *
 *   while (neug_result_step(r)) { read the row with the getters }
 */
NEUG_C_API int32_t neug_result_step(neug_result* result);
NEUG_C_API void neug_result_rewind(neug_result* result);

NEUG_C_API int32_t neug_result_is_null(neug_result* result, size_t column, int32_t* out,
                                       neug_error** err);
NEUG_C_API int32_t neug_result_get_bool(neug_result* result, size_t column, uint8_t* out,
                                        neug_error** err);
NEUG_C_API int32_t neug_result_get_i32(neug_result* result, size_t column, int32_t* out,
                                       neug_error** err);
NEUG_C_API int32_t neug_result_get_u32(neug_result* result, size_t column, uint32_t* out,
                                       neug_error** err);
NEUG_C_API int32_t neug_result_get_i64(neug_result* result, size_t column, int64_t* out,
                                       neug_error** err);
NEUG_C_API int32_t neug_result_get_u64(neug_result* result, size_t column, uint64_t* out,
                                       neug_error** err);
NEUG_C_API int32_t neug_result_get_f32(neug_result* result, size_t column, float* out,
                                       neug_error** err);
NEUG_C_API int32_t neug_result_get_f64(neug_result* result, size_t column, double* out,
                                       neug_error** err);
/* The text is not NUL-terminated by contract (it may hold NULs): use *len. */
NEUG_C_API int32_t neug_result_get_string(neug_result* result, size_t column, const char** ptr,
                                          size_t* len, neug_error** err);
NEUG_C_API void neug_result_free(neug_result* result);

#ifdef __cplusplus
}
#endif

#endif /* NEUG_C_H */
