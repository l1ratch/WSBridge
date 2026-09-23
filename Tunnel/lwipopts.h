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
#define MEMP_NUM_TCP_PCB_LISTEN 8
#define MEMP_NUM_TCP_SEG        256
#define MEMP_NUM_PBUF           64
#define PBUF_POOL_SIZE          128
#define PBUF_POOL_BUFSIZE       1600

#define TCP_SND_BUF             65536
#define TCP_WND                 65535
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

#endif
