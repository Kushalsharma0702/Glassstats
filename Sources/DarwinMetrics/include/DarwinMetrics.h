#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sqlite3.h>

typedef struct { uint32_t user, system, idle, nice; } GSCPUTicks;
size_t gs_cpu(GSCPUTicks **rows);

typedef struct {
    uint64_t total, internal, wired, compressed, purgeable, external, swap;
    bool has_swap;
} GSMemory;
bool gs_memory(GSMemory *memory);

typedef struct { uint64_t received, sent; } GSNetwork;
bool gs_network(const char *name, GSNetwork *counters);

typedef struct {
    int32_t pid;
    uint64_t started, cpu_ns, footprint;
    char name[256];
} GSProcess;

typedef struct {
    GSProcess owner;
    uint16_t port;
    bool tcp, ipv6, loopback, wildcard, connected;
    char address[96], service[64];
} GSSocket;

bool gs_process(int32_t pid, GSProcess *row);
size_t gs_processes(GSProcess **rows);
size_t gs_sockets(GSSocket **rows, size_t *inspected, size_t *inaccessible);
bool gs_can_stop_listener(int32_t pid, uint64_t started);
bool gs_stop_listener(int32_t pid, uint64_t started);
bool gs_docker_list(const char *path, char **bytes, size_t *length);
