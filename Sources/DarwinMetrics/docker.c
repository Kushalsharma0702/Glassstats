#include "DarwinMetrics.h"
#include <curl/curl.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

static const size_t limit = 1024 * 1024;
static pthread_once_t curl_once = PTHREAD_ONCE_INIT;
static CURLcode curl_status = CURLE_FAILED_INIT;

static void initialize_curl(void) {
    curl_status = curl_global_init(CURL_GLOBAL_DEFAULT);
}

struct response { char *bytes; size_t length, capacity; };

static size_t receive(char *input, size_t size, size_t count, void *context) {
    struct response *response = context;
    if (!size || count > (limit - response->length) / size) return 0;
    size_t bytes = size * count;
    size_t needed = response->length + bytes;
    if (needed > response->capacity) {
        size_t capacity = response->capacity ? response->capacity * 2 : 4096;
        if (capacity < needed) capacity = needed;
        char *buffer = realloc(response->bytes, capacity);
        if (!buffer) return 0;
        response->bytes = buffer;
        response->capacity = capacity;
    }
    memcpy(response->bytes + response->length, input, bytes);
    response->length += bytes;
    return bytes;
}

bool gs_docker_list(const char *path, char **bytes, size_t *length) {
    *bytes = NULL;
    *length = 0;
    pthread_once(&curl_once, initialize_curl);
    if (curl_status != CURLE_OK) return false;
    CURL *curl = curl_easy_init();
    if (!curl) return false;
    struct response response = {0};
    // Fail closed if this libcurl cannot configure the local transport.
    bool configured =
        curl_easy_setopt(curl, CURLOPT_UNIX_SOCKET_PATH, path) == CURLE_OK &&
        curl_easy_setopt(curl, CURLOPT_PROXY, "") == CURLE_OK &&
        curl_easy_setopt(curl, CURLOPT_URL, "http://localhost/containers/json?all=1") == CURLE_OK &&
        curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT_MS, 400L) == CURLE_OK &&
        curl_easy_setopt(curl, CURLOPT_TIMEOUT_MS, 1400L) == CURLE_OK &&
        curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L) == CURLE_OK &&
        curl_easy_setopt(curl, CURLOPT_FAILONERROR, 1L) == CURLE_OK &&
        curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, receive) == CURLE_OK &&
        curl_easy_setopt(curl, CURLOPT_WRITEDATA, &response) == CURLE_OK;
    long status = 0;
    bool success = configured && curl_easy_perform(curl) == CURLE_OK &&
                   curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status) == CURLE_OK && status == 200;
    curl_easy_cleanup(curl);
    if (!success) {
        free(response.bytes);
        return false;
    }
    *bytes = response.bytes;
    *length = response.length;
    return true;
}
