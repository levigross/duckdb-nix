// The C interface of NeuG (neug_c.h) over its C++ one. See the header for what it promises.
#include "neug_c.h"

#include <neug/neug.h>
#include <neug/version.h>
#include <rapidjson/document.h>

#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <utility>
#include <vector>

// The headers of NeuG branch on this, and the library is built with it: the CMake package
// exports it. Without it the types in them are not the ones the library has.
#ifndef NEUG_WITH_MIMALLOC
#error "NEUG_WITH_MIMALLOC is not defined: find_package(neug) of this version defines it"
#endif

// The numbers of neug_type are those of the protobuf of the responses.
#define NEUG_SAME_TYPE(a, b) static_assert(static_cast<int>(neug::Array::a) == (b), #a)
NEUG_SAME_TYPE(kInt32Array, NEUG_T_INT32);
NEUG_SAME_TYPE(kUint32Array, NEUG_T_UINT32);
NEUG_SAME_TYPE(kInt64Array, NEUG_T_INT64);
NEUG_SAME_TYPE(kUint64Array, NEUG_T_UINT64);
NEUG_SAME_TYPE(kFloatArray, NEUG_T_FLOAT);
NEUG_SAME_TYPE(kDoubleArray, NEUG_T_DOUBLE);
NEUG_SAME_TYPE(kStringArray, NEUG_T_STRING);
NEUG_SAME_TYPE(kBoolArray, NEUG_T_BOOL);
NEUG_SAME_TYPE(kTimestampArray, NEUG_T_TIMESTAMP);
NEUG_SAME_TYPE(kDateArray, NEUG_T_DATE);
NEUG_SAME_TYPE(kIntervalArray, NEUG_T_INTERVAL);
NEUG_SAME_TYPE(kListArray, NEUG_T_LIST);
NEUG_SAME_TYPE(kStructArray, NEUG_T_STRUCT);
NEUG_SAME_TYPE(kVertexArray, NEUG_T_VERTEX);
NEUG_SAME_TYPE(kEdgeArray, NEUG_T_EDGE);
NEUG_SAME_TYPE(kPathArray, NEUG_T_PATH);

struct neug_error {
  int32_t code;
  std::string message;
};

struct neug_db {
  neug::NeugDB db;
};

struct neug_conn {
  std::shared_ptr<neug::Connection> conn;
};

struct neug_result {
  explicit neug_result(neug::QueryResult&& r) : qr(std::move(r)) {}
  neug::QueryResult qr;
  bool started = false;
  std::vector<std::string> names;
  std::vector<int32_t> types;
  std::string scratch;
};

namespace {

// NeuG initializes a parser of its plans as a singleton while a database opens and closes
std::mutex& life() {
  static std::mutex mutex;
  return mutex;
}

int32_t fail(neug_error** err, int32_t code, std::string message) {
  // a code of NeuG that would read as success or as NULL is not one
  if (code == NEUG_OK || code == NEUG_NULL) code = NEUG_E_OTHER;
  if (err != nullptr) {
    try {
      *err = new neug_error{code, std::move(message)};
    } catch (...) {
      *err = nullptr;
    }
  }
  return code;
}

int32_t fail(neug_error** err, const neug::Status& status) {
  return fail(err, static_cast<int32_t>(status.error_code()), status.error_message());
}

// Nothing thrown by the engine leaves through the C interface.
template <class F>
int32_t guard(neug_error** err, F&& body) noexcept {
  try {
    return body();
  } catch (const std::exception& e) {
    return fail(err, NEUG_E_EXCEPTION, e.what());
  } catch (...) {
    return fail(err, NEUG_E_OTHER, "an exception that is not a std::exception");
  }
}

const char* access_mode(neug_access access) {
  switch (access) {
    case NEUG_ACCESS_READ:
      return "read";
    case NEUG_ACCESS_INSERT:
      return "insert";
    case NEUG_ACCESS_UPDATE:
      return "update";
    case NEUG_ACCESS_SCHEMA:
      return "schema";
    default:
      return "";
  }
}

// Which types of column a getter reads: what the engine widens (query_result.cc), so that a
// mismatch is an error of ours and not an exception of the engine.
enum Reads : uint32_t {
  kBool = 1u << NEUG_T_BOOL,
  kI32 = 1u << NEUG_T_INT32,
  kU32 = 1u << NEUG_T_UINT32,
  kI64 = 1u << NEUG_T_INT64,
  kU64 = 1u << NEUG_T_UINT64,
  kF32 = 1u << NEUG_T_FLOAT,
  kF64 = 1u << NEUG_T_DOUBLE,
  kDate = 1u << NEUG_T_DATE,
  kTimestamp = 1u << NEUG_T_TIMESTAMP,
  kAnyType = 0xFFFFFFFFu
};

template <class T, class Read>
int32_t get(neug_result* result, size_t column, T* out, neug_error** err, uint32_t reads,
            const char* what, Read&& read) {
  if (result == nullptr || out == nullptr) {
    return fail(err, NEUG_E_NULL_ARGUMENT, "a NULL pointer");
  }
  return guard(err, [&]() -> int32_t {
    if (!result->started || !result->qr.hasNext()) {
      return fail(err, NEUG_E_NO_ROW, "the cursor is not on a row: call neug_result_step");
    }
    if (column >= result->names.size()) {
      return fail(err, NEUG_E_COLUMN, "no such column");
    }
    if (result->qr.IsNull(column)) return NEUG_NULL;
    const int32_t type = result->types[column];
    if (type <= 0 || type > 31 || (reads & (1u << type)) == 0) {
      return fail(err, NEUG_E_TYPE,
                  std::string("column ") + result->names[column] + " cannot be read as " + what);
    }
    *out = read(result->qr, column);
    return NEUG_OK;
  });
}

}  // namespace

extern "C" {

uint32_t neug_c_abi_version(void) { return NEUG_C_ABI_VERSION; }

const char* neug_c_version(void) { return NEUG_VERSION_STRING; }

void neug_open_options_init(neug_open_options* options) {
  if (options == nullptr) return;
  options->struct_size = sizeof(neug_open_options);
  options->path = nullptr;
  options->max_threads = 0;
  options->read_only = 0;
  options->checkpoint_on_close = 1;
}

int32_t neug_error_code(const neug_error* error) {
  return error != nullptr ? error->code : NEUG_E_NULL_ARGUMENT;
}

const char* neug_error_message(const neug_error* error) {
  return error != nullptr ? error->message.c_str() : "";
}

void neug_error_free(neug_error* error) { delete error; }

int32_t neug_db_open(const neug_open_options* options, neug_db** out, neug_error** err) {
  if (options == nullptr || out == nullptr) {
    return fail(err, NEUG_E_NULL_ARGUMENT, "a NULL pointer");
  }
  if (options->struct_size < sizeof(neug_open_options)) {
    return fail(err, NEUG_E_ABI, "neug_open_options was not initialized by neug_open_options_init");
  }
  *out = nullptr;
  return guard(err, [&]() -> int32_t {
    std::lock_guard<std::mutex> lock(life());
    auto handle = std::make_unique<neug_db>();
    const std::string path = options->path != nullptr ? options->path : "";
    // a database that is not opened is closed already, so its destructor has nothing to do
    if (!handle->db.Open(path, options->max_threads,
                         options->read_only != 0 ? neug::DBMode::READ_ONLY
                                                 : neug::DBMode::READ_WRITE,
                         "gopt", options->checkpoint_on_close != 0)) {
      return fail(err, NEUG_E_OTHER, "NeugDB::Open returned false");
    }
    *out = handle.release();
    return NEUG_OK;
  });
}

int32_t neug_db_close(neug_db* db, neug_error** err) {
  if (db == nullptr) return fail(err, NEUG_E_NULL_ARGUMENT, "a NULL pointer");
  return guard(err, [&]() -> int32_t {
    std::lock_guard<std::mutex> lock(life());
    if (!db->db.IsClosed()) db->db.Close();
    return NEUG_OK;
  });
}

void neug_db_free(neug_db* db) {
  if (db == nullptr) return;
  std::lock_guard<std::mutex> lock(life());
  try {
    if (!db->db.IsClosed()) db->db.Close();
  } catch (...) {
  }
  // The destructor of a database that is not closed ends the process (LOG(FATAL)): if closing
  // failed, the database is leaked, which is better than that.
  if (db->db.IsClosed()) delete db;
}

int32_t neug_conn_open(neug_db* db, neug_conn** out, neug_error** err) {
  if (db == nullptr || out == nullptr) {
    return fail(err, NEUG_E_NULL_ARGUMENT, "a NULL pointer");
  }
  *out = nullptr;
  return guard(err, [&]() -> int32_t {
    auto connection = db->db.Connect();
    if (!connection) return fail(err, NEUG_E_OTHER, "NeugDB::Connect returned no connection");
    *out = new neug_conn{std::move(connection)};
    return NEUG_OK;
  });
}

void neug_conn_free(neug_conn* conn) {
  if (conn == nullptr) return;
  try {
    conn->conn->Close();
  } catch (...) {
    // the destructor of a connection calls Close again and must not throw: keep it alive
    new std::shared_ptr<neug::Connection>(std::move(conn->conn));
  }
  delete conn;
}

int32_t neug_conn_query(neug_conn* conn, const char* cypher, neug_access access,
                        const char* params_json, neug_result** out, neug_error** err) {
  if (conn == nullptr || cypher == nullptr || out == nullptr) {
    return fail(err, NEUG_E_NULL_ARGUMENT, "a NULL pointer");
  }
  *out = nullptr;
  return guard(err, [&]() -> int32_t {
    rapidjson::Document params(rapidjson::kObjectType);
    if (params_json != nullptr && *params_json != '\0') {
      params.Parse(params_json);
      if (params.HasParseError() || !params.IsObject()) {
        return fail(err, NEUG_E_PARAMETERS, "the parameters are not a JSON object");
      }
    }
    auto answer = conn->conn->Query(cypher, access_mode(access), params);
    if (!answer) return fail(err, answer.error());
    auto result = std::make_unique<neug_result>(std::move(answer).value());
    result->names = result->qr.ColumnNames();
    const auto& arrays = result->qr.response().arrays();
    for (size_t i = 0; i < result->names.size(); ++i) {
      result->types.push_back(i < static_cast<size_t>(arrays.size())
                                  ? static_cast<int32_t>(arrays[static_cast<int>(i)].typed_array_case())
                                  : NEUG_T_UNSET);
    }
    *out = result.release();
    return NEUG_OK;
  });
}

int32_t neug_conn_begin(neug_conn* conn, int32_t read_only, neug_error** err) {
  if (conn == nullptr) return fail(err, NEUG_E_NULL_ARGUMENT, "a NULL pointer");
  return guard(err, [&]() -> int32_t {
    const auto status = conn->conn->BeginTransaction(read_only != 0 ? neug::TransactionMode::kReadOnly
                                                                    : neug::TransactionMode::kReadWrite);
    return status.ok() ? NEUG_OK : fail(err, status);
  });
}

int32_t neug_conn_commit(neug_conn* conn, neug_error** err) {
  if (conn == nullptr) return fail(err, NEUG_E_NULL_ARGUMENT, "a NULL pointer");
  return guard(err, [&]() -> int32_t {
    const auto status = conn->conn->Commit();
    return status.ok() ? NEUG_OK : fail(err, status);
  });
}

int32_t neug_conn_rollback(neug_conn* conn, neug_error** err) {
  if (conn == nullptr) return fail(err, NEUG_E_NULL_ARGUMENT, "a NULL pointer");
  return guard(err, [&]() -> int32_t {
    const auto status = conn->conn->Rollback();
    return status.ok() ? NEUG_OK : fail(err, status);
  });
}

int32_t neug_conn_in_transaction(const neug_conn* conn) {
  return conn != nullptr && conn->conn->HasActiveTransaction() ? 1 : 0;
}

size_t neug_result_rows(const neug_result* result) {
  return result != nullptr ? result->qr.length() : 0;
}

size_t neug_result_columns(const neug_result* result) {
  return result != nullptr ? result->names.size() : 0;
}

const char* neug_result_column_name(const neug_result* result, size_t column) {
  return result != nullptr && column < result->names.size() ? result->names[column].c_str() : "";
}

neug_type neug_result_column_type(const neug_result* result, size_t column) {
  return result != nullptr && column < result->types.size() ? static_cast<neug_type>(result->types[column])
                                                            : NEUG_T_UNSET;
}

int32_t neug_result_step(neug_result* result) {
  if (result == nullptr) return 0;
  try {
    if (result->started && result->qr.hasNext()) result->qr.next();
    result->started = true;
    return result->qr.hasNext() ? 1 : 0;
  } catch (...) {
    return 0;
  }
}

void neug_result_rewind(neug_result* result) {
  if (result == nullptr) return;
  result->qr.Reset();
  result->started = false;
}

int32_t neug_result_is_null(neug_result* result, size_t column, int32_t* out, neug_error** err) {
  if (result == nullptr || out == nullptr) {
    return fail(err, NEUG_E_NULL_ARGUMENT, "a NULL pointer");
  }
  return guard(err, [&]() -> int32_t {
    if (!result->started || !result->qr.hasNext()) {
      return fail(err, NEUG_E_NO_ROW, "the cursor is not on a row: call neug_result_step");
    }
    if (column >= result->names.size()) return fail(err, NEUG_E_COLUMN, "no such column");
    *out = result->qr.IsNull(column) ? 1 : 0;
    return NEUG_OK;
  });
}

int32_t neug_result_get_bool(neug_result* r, size_t c, uint8_t* out, neug_error** err) {
  return get(r, c, out, err, kBool, "bool",
             [](neug::QueryResult& q, size_t i) { return static_cast<uint8_t>(q.GetBool(i) ? 1 : 0); });
}

int32_t neug_result_get_i32(neug_result* r, size_t c, int32_t* out, neug_error** err) {
  return get(r, c, out, err, kI32 | kBool, "i32",
             [](neug::QueryResult& q, size_t i) { return q.GetInt32(i); });
}

int32_t neug_result_get_u32(neug_result* r, size_t c, uint32_t* out, neug_error** err) {
  return get(r, c, out, err, kU32 | kBool, "u32",
             [](neug::QueryResult& q, size_t i) { return q.GetUInt32(i); });
}

int32_t neug_result_get_i64(neug_result* r, size_t c, int64_t* out, neug_error** err) {
  return get(r, c, out, err, kI64 | kI32 | kU32 | kBool | kDate | kTimestamp, "i64",
             [](neug::QueryResult& q, size_t i) { return q.GetInt64(i); });
}

int32_t neug_result_get_u64(neug_result* r, size_t c, uint64_t* out, neug_error** err) {
  return get(r, c, out, err, kU64 | kU32 | kBool, "u64",
             [](neug::QueryResult& q, size_t i) { return q.GetUInt64(i); });
}

int32_t neug_result_get_f32(neug_result* r, size_t c, float* out, neug_error** err) {
  return get(r, c, out, err, kF32 | kI32 | kU32 | kBool, "f32",
             [](neug::QueryResult& q, size_t i) { return q.GetFloat(i); });
}

int32_t neug_result_get_f64(neug_result* r, size_t c, double* out, neug_error** err) {
  return get(r, c, out, err, kF64 | kF32 | kI32 | kU32 | kI64 | kU64 | kBool, "f64",
             [](neug::QueryResult& q, size_t i) { return q.GetDouble(i); });
}

int32_t neug_result_get_string(neug_result* result, size_t column, const char** ptr, size_t* len,
                               neug_error** err) {
  if (ptr == nullptr || len == nullptr) {
    return fail(err, NEUG_E_NULL_ARGUMENT, "a NULL pointer");
  }
  std::string* text = result != nullptr ? &result->scratch : nullptr;
  std::string* out = nullptr;
  const int32_t status =
      get(result, column, &out, err, kAnyType, "string", [text](neug::QueryResult& q, size_t i) {
        *text = q.GetString(i);
        return text;
      });
  if (status == NEUG_OK) {
    *ptr = out->data();
    *len = out->size();
  }
  return status;
}

void neug_result_free(neug_result* result) { delete result; }

}  // extern "C"
