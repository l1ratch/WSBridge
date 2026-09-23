#include "lwip_bridge.h"
#include "lwip/init.h"
#include "lwip/ip.h"
#include "lwip/tcp.h"
#include "lwip/netif.h"
#include "lwip/pbuf.h"
#include "lwip/timeouts.h"
#include "lwip/ip4_addr.h"
#include "lwip/priv/tcp_priv.h"
#include <string.h>
#include <stdlib.h>

static struct netif g_netif;
static void *g_ctx;
static lwip_output_cb g_output;
static lwip_accept_cb g_accept;
static lwip_recv_cb g_recv;
static lwip_close_cb g_close;
static lwip_sent_cb g_sent;

// --- NAT table: (client_ip, client_port) -> original DC IP ---
#define NAT_MAX 128
typedef struct {
    uint32_t client_ip;
    uint16_t client_port;
    uint32_t dc_ip;
    int used;
} nat_entry_t;
static nat_entry_t g_nat[NAT_MAX];

static void nat_add(uint32_t client_ip, uint16_t client_port, uint32_t dc_ip) {
    // Reuse existing entry or find a free slot
    for (int i = 0; i < NAT_MAX; i++) {
        if (g_nat[i].used && g_nat[i].client_ip == client_ip && g_nat[i].client_port == client_port) {
            g_nat[i].dc_ip = dc_ip;
            return;
        }
    }
    for (int i = 0; i < NAT_MAX; i++) {
        if (!g_nat[i].used) {
            g_nat[i].client_ip = client_ip;
            g_nat[i].client_port = client_port;
            g_nat[i].dc_ip = dc_ip;
            g_nat[i].used = 1;
            return;
        }
    }
}

static uint32_t nat_lookup(uint32_t client_ip, uint16_t client_port) {
    for (int i = 0; i < NAT_MAX; i++) {
        if (g_nat[i].used && g_nat[i].client_ip == client_ip && g_nat[i].client_port == client_port) {
            return g_nat[i].dc_ip;
        }
    }
    return 0;
}

static void nat_remove(uint32_t client_ip, uint16_t client_port) {
    for (int i = 0; i < NAT_MAX; i++) {
        if (g_nat[i].used && g_nat[i].client_ip == client_ip && g_nat[i].client_port == client_port) {
            g_nat[i].used = 0;
            return;
        }
    }
}

// --- Connection tracking ---
#define MAX_CONNS 64
typedef struct {
    struct tcp_pcb *pcb;
    uint32_t dc_ip;
    uint32_t client_ip;
    uint16_t client_port;
    int active;
} conn_t;
static conn_t g_conns[MAX_CONNS];

// Forward declarations
static err_t tcp_recv_cb(void *arg, struct tcp_pcb *pcb, struct pbuf *p, err_t err);
static void tcp_err_cb(void *arg, err_t err);
static err_t tcp_sent_cb(void *arg, struct tcp_pcb *pcb, u16_t len);
static err_t tcp_accept_cb(void *arg, struct tcp_pcb *newpcb, err_t err);

static conn_t *conn_of_id(uint32_t id) {
    if (id >= MAX_CONNS || !g_conns[id].active) return NULL;
    return &g_conns[id];
}

// --- lwIP netif callbacks ---

static err_t netif_output(struct netif *netif, struct pbuf *p, const ip4_addr_t *ipaddr) {
    (void)netif; (void)ipaddr;
    if (!g_output) return ERR_OK;

    uint16_t total = p->tot_len;
    uint8_t *buf = (uint8_t *)malloc(total);
    if (!buf) return ERR_MEM;
    uint16_t copied = pbuf_copy_partial(p, buf, total, 0);
    if (copied != total) { free(buf); return ERR_OK; }

    // NAT: rewrite source IP from 198.18.0.2 back to original DC IP
    if (total >= 20) {
        uint32_t src_ip = ((uint32_t)buf[12] << 24) | ((uint32_t)buf[13] << 16) |
                          ((uint32_t)buf[14] << 8)  | (uint32_t)buf[15];
        uint32_t dst_ip = ((uint32_t)buf[16] << 24) | ((uint32_t)buf[17] << 16) |
                          ((uint32_t)buf[18] << 8)  | (uint32_t)buf[19];
        // src should be 198.18.0.2 (0xC6120002)
        if (src_ip == 0xC6120002) {
            uint32_t dc_ip = 0;
            // Try with port from TCP header
            if (total >= 40) {
                uint16_t dst_port = ((uint16_t)buf[22] << 8) | buf[23];
                dc_ip = nat_lookup(dst_ip, dst_port);
            }
            if (!dc_ip) {
                // Fallback: lookup by client_ip only
                dc_ip = nat_lookup(dst_ip, 0);
            }
            if (dc_ip) {
                buf[12] = (dc_ip >> 24) & 0xFF;
                buf[13] = (dc_ip >> 16) & 0xFF;
                buf[14] = (dc_ip >> 8) & 0xFF;
                buf[15] = dc_ip & 0xFF;

                // Recalculate IP checksum
                buf[10] = 0; buf[11] = 0;
                uint32_t sum = 0;
                for (int i = 0; i < 20; i += 2) {
                    sum += ((uint16_t)buf[i] << 8) | buf[i+1];
                }
                while (sum >> 16) sum = (sum & 0xFFFF) + (sum >> 16);
                uint16_t csum = (uint16_t)~sum;
                buf[10] = (csum >> 8) & 0xFF;
                buf[11] = csum & 0xFF;

                // Recalculate TCP checksum (pseudo-header changed)
                if (total >= 40) {
                    uint8_t proto = buf[9];
                    if (proto == 6) { // TCP
                        // Zero out TCP checksum
                        buf[36] = 0; buf[37] = 0;
                        // Pseudo-header: src_ip, dst_ip, zero, proto, tcp_len
                        uint16_t tcp_len = total - 20;
                        uint32_t sum2 = 0;
                        // Pseudo-header
                        sum2 += ((uint16_t)buf[12] << 8) | buf[13];
                        sum2 += ((uint16_t)buf[14] << 8) | buf[15];
                        sum2 += ((uint16_t)buf[16] << 8) | buf[17];
                        sum2 += ((uint16_t)buf[18] << 8) | buf[19];
                        sum2 += proto;
                        sum2 += tcp_len;
                        // TCP segment
                        for (int i = 20; i < total; i += 2) {
                            uint16_t word = ((uint16_t)buf[i] << 8);
                            if (i + 1 < total) word |= buf[i+1];
                            sum2 += word;
                        }
                        while (sum2 >> 16) sum2 = (sum2 & 0xFFFF) + (sum2 >> 16);
                        uint16_t tcp_csum = (uint16_t)~sum2;
                        buf[36] = (tcp_csum >> 8) & 0xFF;
                        buf[37] = tcp_csum & 0xFF;
                    }
                }
            }
        }
    }

    g_output(buf, total, g_ctx);
    free(buf);
    return ERR_OK;
}

static err_t netif_init_cb(struct netif *netif) {
    netif->name[0] = 'w';
    netif->name[1] = 's';
    netif->output = netif_output;
    netif->mtu = 1500;
    netif->flags = NETIF_FLAG_UP | NETIF_FLAG_LINK_UP;
    return ERR_OK;
}

// --- TCP callbacks ---

static err_t tcp_accept_cb(void *arg, struct tcp_pcb *newpcb, err_t err) {
    (void)arg;
    if (err != ERR_OK || !newpcb) return ERR_OK;

    uint32_t client_ip = ip4_addr_get_u32(&newpcb->remote_ip);
    uint16_t client_port = newpcb->remote_port;
    uint32_t dc_ip = nat_lookup(client_ip, client_port);

    int slot = -1;
    for (int i = 0; i < MAX_CONNS; i++) {
        if (!g_conns[i].active) { slot = i; break; }
    }
    if (slot < 0) {
        tcp_abort(newpcb);
        return ERR_OK;
    }

    g_conns[slot].pcb = newpcb;
    g_conns[slot].dc_ip = dc_ip;
    g_conns[slot].client_ip = client_ip;
    g_conns[slot].client_port = client_port;
    g_conns[slot].active = 1;

    tcp_arg(newpcb, (void *)(uintptr_t)slot);
    tcp_recv(newpcb, tcp_recv_cb);
    tcp_err(newpcb, tcp_err_cb);
    tcp_sent(newpcb, tcp_sent_cb);

    if (g_accept) g_accept((uint32_t)slot, g_ctx);
    return ERR_OK;
}

static err_t tcp_recv_cb(void *arg, struct tcp_pcb *pcb, struct pbuf *p, err_t err) {
    uint32_t id = (uint32_t)(uintptr_t)arg;
    if (err != ERR_OK || !p) {
        if (p) pbuf_free(p);
        if (g_close) g_close(id, g_ctx);
        conn_t *c = conn_of_id(id);
        if (c) {
            nat_remove(c->client_ip, c->client_port);
            c->active = 0;
            c->pcb = NULL;
        }
        return ERR_OK;
    }
    if (g_recv) {
        uint16_t total = p->tot_len;
        uint8_t *buf = (uint8_t *)malloc(total);
        if (buf) {
            uint16_t copied = pbuf_copy_partial(p, buf, total, 0);
            if (copied == total) {
                g_recv(id, buf, total, g_ctx);
            }
            free(buf);
        }
    }
    tcp_recved(pcb, p->tot_len);
    pbuf_free(p);
    return ERR_OK;
}

static void tcp_err_cb(void *arg, err_t err) {
    (void)err;
    uint32_t id = (uint32_t)(uintptr_t)arg;
    if (g_close) g_close(id, g_ctx);
    conn_t *c = conn_of_id(id);
    if (c) {
        nat_remove(c->client_ip, c->client_port);
        c->active = 0;
        c->pcb = NULL;
    }
}

static err_t tcp_sent_cb(void *arg, struct tcp_pcb *pcb, u16_t len) {
    (void)pcb; (void)len;
    uint32_t id = (uint32_t)(uintptr_t)arg;
    if (g_sent) g_sent(id, g_ctx);
    return ERR_OK;
}

// --- Public API ---

void lwip_bridge_init(void *ctx,
                      lwip_output_cb output,
                      lwip_accept_cb accept,
                      lwip_recv_cb recv,
                      lwip_close_cb close,
                      lwip_sent_cb sent) {
    g_ctx = ctx;
    g_output = output;
    g_accept = accept;
    g_recv = recv;
    g_close = close;
    g_sent = sent;

    memset(g_conns, 0, sizeof(g_conns));
    memset(g_nat, 0, sizeof(g_nat));

    lwip_init();

    ip4_addr_t addr, netmask, gw;
    IP4_ADDR(&addr, 198, 18, 0, 2);
    IP4_ADDR(&netmask, 255, 255, 255, 255);
    IP4_ADDR(&gw, 0, 0, 0, 0);

    netif_add(&g_netif, &addr, &netmask, &gw, NULL, netif_init_cb, ip_input);
    netif_set_up(&g_netif);
    netif_set_default(&g_netif);

    // Listen on port 443
    struct tcp_pcb *listen_pcb = tcp_new();
    if (listen_pcb) {
        tcp_bind(listen_pcb, IP4_ADDR_ANY, 443);
        struct tcp_pcb *l = tcp_listen(listen_pcb);
        if (l) {
            tcp_accept(l, tcp_accept_cb);
        }
    }
}

void lwip_bridge_input(const uint8_t *data, uint16_t len) {
    if (len < 40) return; // IP(20) + TCP(20) minimum

    // Parse original IPs and ports
    uint32_t orig_dst = ((uint32_t)data[16] << 24) | ((uint32_t)data[17] << 16) |
                        ((uint32_t)data[18] << 8)  | (uint32_t)data[19];
    uint32_t src_ip   = ((uint32_t)data[12] << 24) | ((uint32_t)data[13] << 16) |
                        ((uint32_t)data[14] << 8)  | (uint32_t)data[15];
    uint16_t src_port = ((uint16_t)data[20] << 8) | data[21];

    // Store NAT mapping
    nat_add(src_ip, src_port, orig_dst);

    // Rewrite destination IP to our netif address
    uint8_t *buf = (uint8_t *)malloc(len);
    if (!buf) return;
    memcpy(buf, data, len);
    buf[16] = 198; buf[17] = 18; buf[18] = 0; buf[19] = 2;

    // Recalculate IP checksum
    buf[10] = 0; buf[11] = 0;
    uint32_t sum = 0;
    for (int i = 0; i < 20; i += 2) {
        sum += ((uint16_t)buf[i] << 8) | buf[i+1];
    }
    while (sum >> 16) sum = (sum & 0xFFFF) + (sum >> 16);
    uint16_t csum = (uint16_t)~sum;
    buf[10] = (csum >> 8) & 0xFF;
    buf[11] = csum & 0xFF;

    struct pbuf *p = pbuf_alloc(PBUF_RAW, len, PBUF_RAM);
    if (!p) { free(buf); return; }
    memcpy(p->payload, buf, len);
    free(buf);

    g_netif.input(p, &g_netif);
}

void lwip_bridge_poll(void) {
    sys_check_timeouts();
}

int lwip_bridge_write(uint32_t conn_id, const uint8_t *data, uint16_t len) {
    conn_t *c = conn_of_id(conn_id);
    if (!c || !c->pcb) return -1;
    err_t err = tcp_write(c->pcb, data, len, TCP_WRITE_FLAG_COPY);
    if (err == ERR_OK) {
        tcp_output(c->pcb);
        return 0;
    }
    return -1;
}

void lwip_bridge_close(uint32_t conn_id) {
    conn_t *c = conn_of_id(conn_id);
    if (!c || !c->pcb) return;
    nat_remove(c->client_ip, c->client_port);
    tcp_close(c->pcb);
    c->active = 0;
    c->pcb = NULL;
}

uint32_t lwip_bridge_get_dst_ip(uint32_t conn_id) {
    conn_t *c = conn_of_id(conn_id);
    if (!c) return 0;
    return c->dc_ip;
}
