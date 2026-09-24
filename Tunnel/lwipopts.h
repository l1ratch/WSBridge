#ifndef LWIPOPTS_H
#define LWIPOPTS_H

#define NO_SYS                  1
#define LWIP_TCP                1
#define LWIP_UDP                0
#define LWIP_ICMP               1
#define LWIP_ARP                0
#define LWIP_DHCP               0
#define LWIP_DNS                0
#define LWIP_AUTOIP             0
#define LWIP_IGMP               0
#define LWIP_IPV6               0
#define LWIP_NETIF_HOSTNAME     0
#define LWIP_STATS              0
#define LWIP_NETCONN            0
#define LWIP_SOCKET             0

#define MEMP_NUM_TCP_PCB        32
#define MEMP_NUM_TCP_PCB_LISTEN 4
#define MEMP_NUM_TCP_SEG        64
#define MEMP_NUM_PBUF           32
// Куча lwIP (MEM): из неё и входные pbuf (PBUF_RAM в lwip_bridge_input),
// и копии tcp_write. Дефолт 1600 — один сегмент 1460B её исчерпывал:
// ACK клиента дропались на pbuf_alloc, tcp_write давал ERR_MEM при
// пустом окне (wfail:err=-1 wnd=65535 buf=16384 un=0).
#define MEM_SIZE                (128 * 1024)
#define PBUF_POOL_SIZE          64
#define PBUF_POOL_BUFSIZE       1600

#define TCP_SND_BUF             16384
#define TCP_WND                 16384
#define TCP_MSS                 1460

#define LWIP_NETIF_TX_SINGLE_PBUF 1
#define LWIP_CHECKSUM_CTRL_PER_NETIF 0
#define CHECKSUM_GEN_IP         0
#define CHECKSUM_GEN_UDP        0
#define CHECKSUM_GEN_TCP        0
#define CHECKSUM_CHECK_IP       0
#define CHECKSUM_CHECK_UDP      0
#define CHECKSUM_CHECK_TCP      0

#define LWIP_TIMEVAL_PRIVATE    0
#define LWIP_NOASSERT           1

#endif
