import {Socket} from "/assets/phoenix.mjs";
import {LiveSocket} from "/assets/phoenix_live_view.esm.js";
const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
const LogTail = {
  mounted() { this.follow(); },
  beforeUpdate() { this.position = this.el.scrollTop; },
  updated() { this.follow(); },
  follow() {
    this.el.scrollTop = this.el.closest("#case-log").dataset.follow === "true" ? this.el.scrollHeight : (this.position || 0);
  }
};
const liveSocket = new LiveSocket("/live", Socket, {params: {_csrf_token: csrfToken}, hooks: {LogTail}});
liveSocket.connect();
