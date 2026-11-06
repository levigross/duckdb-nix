// A parameter of a small type (an integer, a float, a bool) must read back as what was set.
// A Cube keeps such a value in the storage of a pointer; built with GCC 15 or later and
// optimized, the headers as zvec has them lose it: the parameter reads back as 0, with no error.
// The headers only, no library. PARAM_TYPE and PARAM_VALUE name the type and the value, one
// type to a program: whether the compiler loses the value depends on what else is in the
// program. A value that is not what was set is a non-zero exit.
#include <zvec/ailego/container/params.h>

#include <cstdint>
#include <cstdio>

#ifndef PARAM_TYPE
#error "PARAM_TYPE and PARAM_VALUE name the type and the value to check"
#endif

using zvec::ailego::Params;

// the reader is a function of its own: the value is not known where it is read
template <typename T>
__attribute__((noinline)) static bool read(const Params &params, T *out) {
  return params.get("key", out);
}

int main() {
  // set with a constant lvalue, as the tests of zvec do
  const PARAM_TYPE constant = PARAM_VALUE;
  Params params;
  params.set("key", constant);

  PARAM_TYPE out{};
  if (!read(params, &out)) {
    std::fprintf(stderr, "FAIL: the parameter is not there\n");
    return 1;
  }
  if (out != constant) {
    std::fprintf(stderr, "FAIL: set %g, read %g\n", static_cast<double>(constant),
                 static_cast<double>(out));
    return 1;
  }
  std::puts("ok");
  return 0;
}
