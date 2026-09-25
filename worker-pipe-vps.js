// WSBridge pipe-worker v2 (RELAY): телефон -> CF worker -> твой VPS -> DC по IPv6.
// Заменить код в Cloudflare (Compute -> Workers -> Edit code) -> Deploy.
// Перед деплоем вписать RELAY = адрес VPS:порт, на котором крутится tools/vps_relay.py.
// Контракт с приложением не менялся: /apiws?dst=IP.
import { connect } from "cloudflare:sockets";

const RELAY = "VPS_HOST_OR_IP:7700"; // <-- впиши свой VPS
const SECRET = "wsb1";               // <-- должен совпадать с vps_relay.py

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
		const pair = new WebSocketPair();
		const client = pair[0];
		const server = pair[1];
		server.accept();

		// Сырой TCP к реле (без TLS: connect() воркера и так внутри TLS-сессии CF).
		const [relayHost, relayPortStr] = RELAY.split(":");
		const socket = connect({ hostname: relayHost, port: parseInt(relayPortStr, 10) || 7700 });
		const tcpReader = socket.readable.getReader();
		const tcpWriter = socket.writable.getWriter();

		// Первая строка говорит реле, куда идти; дальше — сырой поток.
		// Записи в один writer идут по порядку, поэтому шапка уйдёт раньше данных.
		tcpWriter.write(new TextEncoder().encode(`${SECRET} ${dst}\n`)).catch(() => {});

		// Fail-fast: если реле не открылось за 4с — закрыть WS, клиент ретраится.
		const failTimer = setTimeout(() => {
			try { server.close(1002, "relay connect timeout"); } catch {}
			try { socket.close(); } catch {}
		}, 4000);
		socket.opened.then(
			() => clearTimeout(failTimer),
			() => {
				clearTimeout(failTimer);
				try { server.close(1002, "relay connect failed"); } catch {}
				try { socket.close(); } catch {}
			}
		);

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
