#include "DarwinMetrics.h"
#include <arpa/inet.h>
#include <libproc.h>
#include <mach/mach.h>
#include <net/if.h>
#include <net/route.h>
#include <netdb.h>
#include <stdio.h>
#include <signal.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>

size_t gs_cpu(GSCPUTicks **rows) {
    *rows = NULL;
    natural_t cores = 0;
    processor_info_array_t info = NULL;
    mach_msg_type_number_t count = 0;
    mach_port_t host = mach_host_self();
    kern_return_t result = host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cores, &info, &count);
    mach_port_deallocate(mach_task_self(), host);
    if (result != KERN_SUCCESS) return 0;
    GSCPUTicks *output = calloc(cores, sizeof(*output));
    if (output && count >= (size_t)cores * CPU_STATE_MAX) {
        for (size_t core = 0; core < cores; core++) {
            integer_t *ticks = info + core * CPU_STATE_MAX;
            output[core] = (GSCPUTicks){ticks[CPU_STATE_USER], ticks[CPU_STATE_SYSTEM],
                                       ticks[CPU_STATE_IDLE], ticks[CPU_STATE_NICE]};
        }
        *rows = output;
    } else {
        free(output);
    }
    vm_deallocate(mach_task_self(), (vm_address_t)info, count * sizeof(*info));
    return *rows ? cores : 0;
}

bool gs_memory(GSMemory *memory) {
    vm_statistics64_data_t vm = {0};
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    mach_port_t host = mach_host_self();
    kern_return_t result = host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&vm, &count);
    mach_port_deallocate(mach_task_self(), host);
    if (result != KERN_SUCCESS || count != HOST_VM_INFO64_COUNT) return false;

    uint64_t total = 0;
    size_t size = sizeof(total);
    if (sysctlbyname("hw.memsize", &total, &size, NULL, 0) != 0) return false;
    struct xsw_usage swap = {0};
    size = sizeof(swap);
    bool has_swap = sysctlbyname("vm.swapusage", &swap, &size, NULL, 0) == 0;
    const uint64_t page = vm_kernel_page_size;
    *memory = (GSMemory){
        .total = total,
        .internal = page * vm.internal_page_count,
        .wired = page * vm.wire_count,
        .compressed = page * vm.compressor_page_count,
        .purgeable = page * vm.purgeable_count,
        .external = page * vm.external_page_count,
        .has_swap = has_swap,
        .swap = swap.xsu_used
    };
    return total > 0;
}

bool gs_network(const char *name, GSNetwork *counters) {
    unsigned int index = if_nametoindex(name);
    if (index == 0) return false;
    int mib[] = { CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, (int)index };
    size_t size = 0;
    if (sysctl(mib, 6, NULL, &size, NULL, 0) != 0 || size == 0) return false;
    char *buffer = malloc(size);
    if (!buffer) return false;
    bool found = false;
    if (sysctl(mib, 6, buffer, &size, NULL, 0) == 0) {
        for (size_t offset = 0; offset + sizeof(struct if_msghdr) <= size;) {
            struct if_msghdr header;
            memcpy(&header, buffer + offset, sizeof(header));
            if (header.ifm_msglen < sizeof(header) || header.ifm_msglen > size - offset) break;
            if (header.ifm_type == RTM_IFINFO2 && header.ifm_index == index &&
                header.ifm_msglen >= sizeof(struct if_msghdr2)) {
                struct if_msghdr2 info;
                memcpy(&info, buffer + offset, sizeof(info));
                *counters = (GSNetwork){info.ifm_data.ifi_ibytes, info.ifm_data.ifi_obytes};
                found = true;
                break;
            }
            offset += header.ifm_msglen;
        }
    }
    free(buffer);
    return found;
}

static int *all_pids(int *count) {
    *count = 0;
    int estimate = proc_listallpids(NULL, 0);
    if (estimate <= 0) return NULL;
    for (int attempt = 0; attempt < 3; attempt++) {
        int capacity = estimate + 64;
        int *pids = calloc((size_t)capacity, sizeof(*pids));
        if (!pids) return NULL;
        int result = proc_listallpids(pids, capacity * (int)sizeof(*pids));
        if (result >= 0 && result < capacity) {
            *count = result;
            return pids;
        }
        free(pids);
        if (result < 0) return NULL;
        estimate = capacity * 2;
    }
    return NULL;
}

static bool process_identity(int32_t pid, GSProcess *row) {
    struct proc_bsdinfo info = {0};
    if (pid <= 0 || proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) return false;
    *row = (GSProcess){.pid = pid, .started = info.pbi_start_tvsec * 1000000ULL + info.pbi_start_tvusec};
    const char *name = info.pbi_name[0] ? info.pbi_name : info.pbi_comm;
    strlcpy(row->name, name[0] ? name : "Unknown process", sizeof(row->name));
    return true;
}

bool gs_process(int32_t pid, GSProcess *row) {
    if (!process_identity(pid, row)) return false;
    struct rusage_info_v2 usage = {0};
    if (proc_pid_rusage(pid, RUSAGE_INFO_V2, (rusage_info_t *)&usage) != 0) return false;
    row->cpu_ns = usage.ri_user_time + usage.ri_system_time;
    row->footprint = usage.ri_phys_footprint;
    return true;
}

size_t gs_processes(GSProcess **rows) {
    *rows = NULL;
    int count;
    int *pids = all_pids(&count);
    if (!pids) return 0;
    GSProcess *output = calloc((size_t)count, sizeof(*output));
    size_t used = 0;
    if (output) {
        for (int i = 0; i < count; i++) {
            if (gs_process(pids[i], &output[used])) used++;
        }
    }
    free(pids);
    *rows = output;
    return used;
}

static bool socket_row(const GSProcess *owner, int fd, GSSocket *row) {
    struct socket_fdinfo info = {0};
    if (proc_pidfdinfo(owner->pid, fd, PROC_PIDFDSOCKETINFO, &info, sizeof(info)) != sizeof(info)) return false;
    const struct socket_info *socket = &info.psi;
    if (socket->soi_family != AF_INET && socket->soi_family != AF_INET6) return false;
    bool tcp = socket->soi_protocol == IPPROTO_TCP;
    const struct in_sockinfo *ip;
    if (tcp && socket->soi_kind == SOCKINFO_TCP && socket->soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN) {
        ip = &socket->soi_proto.pri_tcp.tcpsi_ini;
    } else if (socket->soi_protocol == IPPROTO_UDP && socket->soi_kind == SOCKINFO_IN) {
        ip = &socket->soi_proto.pri_in;
    } else {
        return false;
    }

    uint16_t port = ntohs((uint16_t)ip->insi_lport);
    if (port == 0) return false;
    bool ipv6 = socket->soi_family == AF_INET6;
    *row = (GSSocket){.owner = *owner, .port = port, .tcp = tcp, .ipv6 = ipv6,
                     .connected = !tcp && (socket->soi_state & SOI_S_ISCONNECTED) != 0};
    const struct in6_addr *v6 = &ip->insi_laddr.ina_6;
    const struct in_addr *v4 = &ip->insi_laddr.ina_46.i46a_addr4;
    if (ipv6 && IN6_IS_ADDR_V4MAPPED(v6)) {
        row->loopback = v6->s6_addr[12] == 127;
        row->wildcard = memcmp(v6->s6_addr + 12, "\0\0\0\0", 4) == 0;
    } else if (ipv6) {
        row->loopback = IN6_IS_ADDR_LOOPBACK(v6);
        row->wildcard = IN6_IS_ADDR_UNSPECIFIED(v6);
    } else {
        row->loopback = (ntohl(v4->s_addr) >> 24) == 127;
        row->wildcard = v4->s_addr == INADDR_ANY;
    }
    const void *address = ipv6 ? (const void *)v6 : (const void *)v4;
    if (!inet_ntop(socket->soi_family, address, row->address, sizeof(row->address))) return false;
    if (ipv6 && IN6_IS_ADDR_LINKLOCAL(v6) && ip->insi_v6.in6_ifindex != 0) {
        char interface[IF_NAMESIZE];
        if (if_indextoname(ip->insi_v6.in6_ifindex, interface)) {
            strlcat(row->address, "%", sizeof(row->address));
            strlcat(row->address, interface, sizeof(row->address));
        }
    }
    char *service = row->service;
    struct sockaddr_in endpoint = {.sin_len = sizeof(endpoint), .sin_family = AF_INET, .sin_port = htons(port)};
    const int flags = NI_NAMEREQD | (tcp ? 0 : NI_DGRAM);
    // Only request the service component. No address or DNS lookup is performed.
    if (getnameinfo((struct sockaddr *)&endpoint, sizeof(endpoint), NULL, 0,
                    service, (socklen_t)sizeof(row->service), flags) != 0) *service = '\0';
    if (strcmp(row->service, "0") == 0 || strspn(row->service, "0123456789") == strlen(row->service)) {
        *service = '\0';
    }
    return true;
}

size_t gs_sockets(GSSocket **rows, size_t *inspected, size_t *inaccessible) {
    *rows = NULL;
    *inspected = *inaccessible = 0;
    int count;
    int *pids = all_pids(&count);
    if (!pids) return 0;
    size_t used = 0, capacity = 0;
    struct proc_fdinfo *fds = NULL;
    size_t fd_capacity = 0;
    for (int i = 0; i < count; i++) {
        GSProcess owner;
        if (!process_identity(pids[i], &owner)) continue;
        int estimate = proc_pidinfo(owner.pid, PROC_PIDLISTFDS, 0, NULL, 0);
        if (estimate <= 0) {
            (*inaccessible)++;
            continue;
        }
        int bytes = 0;
        for (int attempt = 0; attempt < 3; attempt++) {
            size_t required = (size_t)estimate + 32 * sizeof(*fds);
            if (required > fd_capacity) {
                void *next = realloc(fds, required);
                if (!next) goto done;
                fds = next;
                fd_capacity = required;
            }
            bytes = proc_pidinfo(owner.pid, PROC_PIDLISTFDS, 0, fds, (int)fd_capacity);
            if (bytes < (int)fd_capacity) break;
            estimate = (int)fd_capacity * 2;
        }
        if (bytes <= 0) {
            (*inaccessible)++;
            continue;
        }
        (*inspected)++;
        size_t process_start = used;
        for (size_t j = 0; j < (size_t)bytes / sizeof(*fds); j++) {
            GSSocket row;
            if (fds[j].proc_fdtype != PROX_FDTYPE_SOCKET || !socket_row(&owner, fds[j].proc_fd, &row)) continue;
            if (used == capacity) {
                size_t next_capacity = capacity ? capacity * 2 : 64;
                void *next = realloc(*rows, sizeof(**rows) * next_capacity);
                if (!next) goto done;
                *rows = next;
                capacity = next_capacity;
            }
            (*rows)[used++] = row;
        }
        GSProcess current;
        if (used != process_start && (!process_identity(owner.pid, &current) || current.started != owner.started)) {
            used = process_start;
        }
    }
done:
    free(fds);
    free(pids);
    return used;
}

bool gs_can_stop_listener(int32_t pid, uint64_t started) {
    uid_t uid = getuid();
    if (uid == 0 || uid != geteuid() || pid <= 1 || pid == getpid()) return false;
    struct proc_bsdinfo owner = {0};
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &owner, sizeof(owner)) != sizeof(owner) ||
        owner.pbi_ruid != uid || owner.pbi_uid != uid ||
        owner.pbi_start_tvsec * 1000000ULL + owner.pbi_start_tvusec != started) return false;

    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (proc_pidpath(pid, path, sizeof(path)) <= 0 || strstr(path, ".app/") != NULL) return false;
    const char *allowed[] = {"/Users/", "/usr/local/", "/opt/", "/private/tmp/", "/private/var/folders/"};
    bool development_path = false;
    for (size_t i = 0; i < sizeof(allowed) / sizeof(allowed[0]); i++) {
        if (strncmp(path, allowed[i], strlen(allowed[i])) == 0) development_path = true;
    }
    if (!development_path) return false;

    pid_t ancestor = getppid();
    for (int depth = 0; ancestor > 1 && depth < 64; depth++) {
        if (pid == ancestor) return false;
        struct proc_bsdinfo parent = {0};
        if (proc_pidinfo(ancestor, PROC_PIDTBSDINFO, 0, &parent, sizeof(parent)) != sizeof(parent)) return false;
        ancestor = parent.pbi_ppid;
    }
    return ancestor <= 1;
}

bool gs_stop_listener(int32_t pid, uint64_t started) {
    return gs_can_stop_listener(pid, started) && kill(pid, SIGTERM) == 0;
}
