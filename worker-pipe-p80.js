// WSBridge pipe-worker, ВАРИАНТ «порт 80». Deploy вместо текущего воркера.
// Зачем: TG глушит MTProto с Cloudflare-эгресса на :443 (проверено 25.09 ночью
// на всех DC). У TG есть антицензурные порты 80/88 — фильтр по CF-адресам
// может не покрывать их. Приложение менять НЕ нужно: порт живёт здесь.
// Обратный ход: /apiws?dst=IP&port=443 (дефолт 80).
import { connect } from "cloudflare:sockets";

function toBytes(data) {
	if (data instanceof ArrayBuffer) {
		return new Uint8Array(data);
	}
	if (typeof data === "string") {
		return new TextEncoder().encode(data);
	}
	if (data && typeof data.arrayBuffer === "function") {
		return data.arrayBuffer().then((ab) => new Uint8Array(ab));
	}
	return new Uint8Array();
}

export default {
	async fetch(request) {
		if ((request.headers.get("Upgrade") || "").toLowerCase() !== "websocket") {
			return new Response("Expected websocket", { status: 426 });
		}

		const url = new URL(request.url);
		if (url.pathname !== "/apiws") {
			return new Response("Not found", { status: 404 });
		}

		const dst = url.searchParams.get("dst");
		const port = parseInt(url.searchParams.get("port") || "80", 10);
		const pair = new WebSocketPair();
		const client = pair[0];
		const server = pair[1];
		server.accept();

		const socket = connect({ hostname: dst, port });

		// Fail-fast: не даём зависшему connect держать WS открытым молча.
		const failTimer = setTimeout(() => {
			try { server.close(1002, "dst connect timeout"); } catch {}
			try { socket.close(); } catch {}
		}, 4000);
		socket.opened.then(
			() => clearTimeout(failTimer),
			() => {
				clearTimeout(failTimer);
				try { server.close(1002, "dst connect failed"); } catch {}
				try { socket.close(); } catch {}
			}
		);

		const tcpReader = socket.readable.getReader();
		const tcpWriter = socket.writable.getWriter();

		server.addEventListener("message", async (event) => {
			try {
				await tcpWriter.write(await toBytes(event.data));
			} catch {
				try {
					server.close(1011, "tcp write failed");
				} catch {}
			}
		});

		server.addEventListener("close", async () => {
			try {
				await tcpWriter.close();
			} catch {}
			try {
				socket.close();
			} catch {}
		});

		(async () => {
			try {
				while (true) {
					const { value, done } = await tcpReader.read();
					if (done) {
						break;
					}
					if (value) {
						server.send(value);
					}
				}
			} catch {
			} finally {
				try {
					server.close();
				} catch {}
				try {
					tcpReader.releaseLock();
				} catch {}
				try {
					socket.close();
				} catch {}
			}
		})();

		return new Response(null, { status: 101, webSocket: client });
	},
};
