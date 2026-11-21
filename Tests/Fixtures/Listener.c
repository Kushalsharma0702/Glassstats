#include <arpa/inet.h>
#include <stdio.h>
#include <sys/socket.h>
#include <unistd.h>

int main(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in address = {
        .sin_len = sizeof(address), .sin_family = AF_INET, .sin_addr = {htonl(INADDR_LOOPBACK)}
    };
    socklen_t length = sizeof(address);
    if (fd < 0 || bind(fd, (struct sockaddr *)&address, length) != 0 || listen(fd, 1) != 0 ||
        getsockname(fd, (struct sockaddr *)&address, &length) != 0) return 1;
    printf("%u\n", ntohs(address.sin_port));
    fflush(stdout);
    for (;;) pause();
}
