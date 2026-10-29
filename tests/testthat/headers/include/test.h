/* A comment with a { brace */
#define TEST_VERSION 1
#include <stddef.h>
DEFINE_STUB(int, foo, (int x), (x))
typedef struct point { int x; int y; /* } */ } point_t;
typedef int (*fun_t)(int x);
extern "C" {
double area(const point_t *p, Box Alias);
}
namespace test {
class Box { public: int w; double width() { return 1.0; } };
using Alias = int;
inline int helper(int x) { return x; }
}
extern int (*geos_area)(fun_t f, Box *b);
MY_EXTERN(point_t) nlopt_style(int n);
inline void register_all(){
  _shifted = (double(*)(const point_t *)) R_GetCCallable("test", "shifted_name");
}
extern fun_t precise_sum;
extern fun_t _p_prefixed;
