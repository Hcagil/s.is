#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

/**
 * Olm round trip through the same wrapper Dart uses: returns 0 when "hi" encrypted by one account decrypts on another, else the number of the failing step (1..5).
 */
int32_t sis_olm_selftest(void);
