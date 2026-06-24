#include <stddef.h>

// sum of all elements in arr
long sum(const int *arr, size_t len) {
    long total = 0;
    for (size_t i = 0; i < len; i++) {
        total += arr[i];
    }
    return total;
}
