// Two processes forked from one that has drawn a UUID draw the same UUIDs.
//
// neug::UUIDGenerator keeps one mt19937 per thread and seeds it from std::random_device once,
// on the first call of the thread. A forked child inherits that state, so every child of a
// parent that has called Generate() produces the sequence of its siblings. NeuG names the
// runtime directory of an open database after a UUID ("runtime/open-<uuid>") and removes it when
// the database closes, so two read-only processes forked from one, opening the same database,
// share a directory that the first to close removes from under the other.
//
// "seeded": the parent draws first, then forks two children that draw one each.
// "fresh":  the parent forks two children without having drawn: each seeds itself.
// Prints "equal" or "different" for the two children's UUIDs.
#include <neug/utils/uuid.h>
#include <sys/wait.h>
#include <unistd.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

namespace {

// the first UUID a child forked from this process draws
pid_t draw_in_child(int write_end, int read_end_to_close) {
  const pid_t pid = ::fork();
  if (pid != 0) {
    return pid;
  }
  ::close(read_end_to_close);
  const std::string uuid = neug::UUIDGenerator::Generate();
  if (::write(write_end, uuid.data(), uuid.size()) !=
      static_cast<ssize_t>(uuid.size())) {
    ::_exit(2);
  }
  ::_exit(0);
}

std::string read_uuid(int fd) {
  char buffer[64] = {};
  const ssize_t n = ::read(fd, buffer, sizeof(buffer) - 1);
  return n > 0 ? std::string(buffer, static_cast<size_t>(n)) : std::string();
}

}  // namespace

int main(int argc, char** argv) {
  if (argc != 2 || (std::strcmp(argv[1], "seeded") != 0 &&
                    std::strcmp(argv[1], "fresh") != 0)) {
    std::fprintf(stderr, "usage: fork_uuid seeded|fresh\n");
    return 2;
  }
  if (std::strcmp(argv[1], "seeded") == 0) {
    neug::UUIDGenerator::Generate();
  }

  int a[2];
  int b[2];
  if (::pipe(a) != 0 || ::pipe(b) != 0) {
    return 2;
  }
  const pid_t first = draw_in_child(a[1], a[0]);
  const pid_t second = draw_in_child(b[1], b[0]);
  ::close(a[1]);
  ::close(b[1]);

  const std::string one = read_uuid(a[0]);
  const std::string two = read_uuid(b[0]);
  int status = 0;
  ::waitpid(first, &status, 0);
  ::waitpid(second, &status, 0);
  if (one.size() != 36 || two.size() != 36) {
    std::fprintf(stderr, "a child did not report a UUID: '%s' '%s'\n",
                 one.c_str(), two.c_str());
    return 2;
  }

  std::printf("%s\n%s\n%s\n", one.c_str(), two.c_str(),
              one == two ? "equal" : "different");
  return 0;
}
