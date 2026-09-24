#ifndef LWIP_BRIDGE_H
#define LWIP_BRIDGE_H

#include <stdint.h>

// Callback: lwIP wants to send a packet to the client (SwiftGram)
typedef void (*lwip_output_cb)(const uint8_t *data, uint16_t len, void *ctx);

// Callback: new TCP connection accepted
typedef void (*lwip_accept_cb)(uint32_t conn_id, void *ctx);

// Callback: TCP data received from client
typedef void (*lwip_recv_cb)(uint32_t conn_id, const uint8_t *data, uint16_t len, void *ctx);

// Callback: TCP connection closed/errored
typedef void (*lwip_close_cb)(uint32_t conn_id, void *ctx);

// Callback: TCP send buffer has space (can write more)
typedef void (*lwip_sent_cb)(uint32_t conn_id, void *ctx);

void lwip_bridge_init(void *ctx,
                      lwip_output_cb output,
                      lwip_accept_cb accept,
                      lwip_recv_cb recv,
                      lwip_close_cb close,
                      lwip_sent_cb sent);

// Feed a raw IPv4 packet (from packetFlow) into lwIP.
// dst_ip will be rewritten to the netif address internally.
void lwip_bridge_input(const uint8_t *data, uint16_t len);

// Call periodically to drive lwIP timers (retransmits, etc.)
void lwip_bridge_poll(void);

// Write data to a TCP connection (from WS → client)
int lwip_bridge_write(uint32_t conn_id, const uint8_t *data, uint16_t len);

// Close a TCP connection
void lwip_bridge_close(uint32_t conn_id);

// Get the original destination IP for a connection (before rewrite)
uint32_t lwip_bridge_get_dst_ip(uint32_t conn_id);

// Diagnostics: last accept-lookup key/result + first live NAT entry
void lwip_bridge_dbg_nat(uint32_t *key_ip, uint16_t *key_port, uint32_t *dc,
                         uint32_t *nat_ip, uint16_t *nat_port, uint32_t *nat_dc);

#endif
