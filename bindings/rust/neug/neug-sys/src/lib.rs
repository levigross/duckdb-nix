//! Raw declarations of the C interface of NeuG (`neug_c.h`). Written by hand: the interface is
//! about thirty functions of opaque handles and scalars, and the header says what each promises.
//! Use the `neug` crate, which wraps them in safe types.

#![allow(non_camel_case_types)]

use std::os::raw::{c_char, c_int};

/// The version of the interface these declarations are of (NEUG_C_ABI_VERSION); the library
/// says which it implements with `neug_c_abi_version`.
pub const ABI_VERSION: u32 = 1;

#[repr(C)]
pub struct neug_db {
    _private: [u8; 0],
}
#[repr(C)]
pub struct neug_conn {
    _private: [u8; 0],
}
#[repr(C)]
pub struct neug_result {
    _private: [u8; 0],
}
#[repr(C)]
pub struct neug_error {
    _private: [u8; 0],
}

pub const NEUG_OK: i32 = 0;
pub const NEUG_NULL: i32 = 1;
pub const NEUG_E_NULL_ARGUMENT: i32 = 10001;
pub const NEUG_E_NO_ROW: i32 = 10002;
pub const NEUG_E_COLUMN: i32 = 10003;
pub const NEUG_E_TYPE: i32 = 10004;
pub const NEUG_E_ABI: i32 = 10005;
pub const NEUG_E_EXCEPTION: i32 = 10006;
pub const NEUG_E_PARAMETERS: i32 = 10007;
pub const NEUG_E_OTHER: i32 = 10008;

/// `neug_access`
pub type neug_access = c_int;
pub const NEUG_ACCESS_INFER: neug_access = 0;
pub const NEUG_ACCESS_READ: neug_access = 1;
pub const NEUG_ACCESS_INSERT: neug_access = 2;
pub const NEUG_ACCESS_UPDATE: neug_access = 3;
pub const NEUG_ACCESS_SCHEMA: neug_access = 4;

/// `neug_type`
pub type neug_type = c_int;
pub const NEUG_T_UNSET: neug_type = 0;
pub const NEUG_T_INT32: neug_type = 1;
pub const NEUG_T_UINT32: neug_type = 2;
pub const NEUG_T_INT64: neug_type = 3;
pub const NEUG_T_UINT64: neug_type = 4;
pub const NEUG_T_FLOAT: neug_type = 5;
pub const NEUG_T_DOUBLE: neug_type = 6;
pub const NEUG_T_STRING: neug_type = 7;
pub const NEUG_T_BOOL: neug_type = 8;
pub const NEUG_T_TIMESTAMP: neug_type = 10;
pub const NEUG_T_DATE: neug_type = 11;
pub const NEUG_T_INTERVAL: neug_type = 12;
pub const NEUG_T_LIST: neug_type = 15;
pub const NEUG_T_STRUCT: neug_type = 16;
pub const NEUG_T_VERTEX: neug_type = 20;
pub const NEUG_T_EDGE: neug_type = 21;
pub const NEUG_T_PATH: neug_type = 22;

#[repr(C)]
pub struct neug_open_options {
    pub struct_size: usize,
    pub path: *const c_char,
    pub max_threads: i32,
    pub read_only: i32,
    pub checkpoint_on_close: i32,
}

extern "C" {
    pub fn neug_c_abi_version() -> u32;
    pub fn neug_c_version() -> *const c_char;
    pub fn neug_open_options_init(options: *mut neug_open_options);

    pub fn neug_error_code(error: *const neug_error) -> i32;
    pub fn neug_error_message(error: *const neug_error) -> *const c_char;
    pub fn neug_error_free(error: *mut neug_error);

    pub fn neug_db_open(
        options: *const neug_open_options,
        out: *mut *mut neug_db,
        err: *mut *mut neug_error,
    ) -> i32;
    pub fn neug_db_close(db: *mut neug_db, err: *mut *mut neug_error) -> i32;
    pub fn neug_db_free(db: *mut neug_db);

    pub fn neug_conn_open(
        db: *mut neug_db,
        out: *mut *mut neug_conn,
        err: *mut *mut neug_error,
    ) -> i32;
    pub fn neug_conn_free(conn: *mut neug_conn);
    pub fn neug_conn_query(
        conn: *mut neug_conn,
        cypher: *const c_char,
        access: neug_access,
        params_json: *const c_char,
        out: *mut *mut neug_result,
        err: *mut *mut neug_error,
    ) -> i32;
    pub fn neug_conn_begin(conn: *mut neug_conn, read_only: i32, err: *mut *mut neug_error) -> i32;
    pub fn neug_conn_commit(conn: *mut neug_conn, err: *mut *mut neug_error) -> i32;
    pub fn neug_conn_rollback(conn: *mut neug_conn, err: *mut *mut neug_error) -> i32;
    pub fn neug_conn_in_transaction(conn: *const neug_conn) -> i32;

    pub fn neug_result_rows(result: *const neug_result) -> usize;
    pub fn neug_result_columns(result: *const neug_result) -> usize;
    pub fn neug_result_column_name(result: *const neug_result, column: usize) -> *const c_char;
    pub fn neug_result_column_type(result: *const neug_result, column: usize) -> neug_type;
    pub fn neug_result_step(result: *mut neug_result) -> i32;
    pub fn neug_result_rewind(result: *mut neug_result);
    pub fn neug_result_is_null(
        result: *mut neug_result,
        column: usize,
        out: *mut i32,
        err: *mut *mut neug_error,
    ) -> i32;
    pub fn neug_result_get_bool(
        result: *mut neug_result,
        column: usize,
        out: *mut u8,
        err: *mut *mut neug_error,
    ) -> i32;
    pub fn neug_result_get_i32(
        result: *mut neug_result,
        column: usize,
        out: *mut i32,
        err: *mut *mut neug_error,
    ) -> i32;
    pub fn neug_result_get_u32(
        result: *mut neug_result,
        column: usize,
        out: *mut u32,
        err: *mut *mut neug_error,
    ) -> i32;
    pub fn neug_result_get_i64(
        result: *mut neug_result,
        column: usize,
        out: *mut i64,
        err: *mut *mut neug_error,
    ) -> i32;
    pub fn neug_result_get_u64(
        result: *mut neug_result,
        column: usize,
        out: *mut u64,
        err: *mut *mut neug_error,
    ) -> i32;
    pub fn neug_result_get_f32(
        result: *mut neug_result,
        column: usize,
        out: *mut f32,
        err: *mut *mut neug_error,
    ) -> i32;
    pub fn neug_result_get_f64(
        result: *mut neug_result,
        column: usize,
        out: *mut f64,
        err: *mut *mut neug_error,
    ) -> i32;
    pub fn neug_result_get_string(
        result: *mut neug_result,
        column: usize,
        ptr: *mut *const c_char,
        len: *mut usize,
        err: *mut *mut neug_error,
    ) -> i32;
    pub fn neug_result_free(result: *mut neug_result);
}
