"""Receptor de alertas del laboratorio: imprime cada alerta que envía Alertmanager.

La ruta de la petición identifica al cliente (/alpha, /beta). En producción este receptor
se reemplaza por el canal real de cada cliente (correo, Slack, webhook propio).
"""
import json
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = 8080


class AlertHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        for alert in json.loads(body).get("alerts", []):
            labels = alert.get("labels", {})
            summary = alert.get("annotations", {}).get("summary", "")
            print(
                f'[{self.path}] {alert.get("status")} {labels.get("alertname")} '
                f'ns={labels.get("namespace")} resource={labels.get("resource", "-")} :: {summary}',
                flush=True,
            )
        self.send_response(200)
        self.end_headers()

    def log_message(self, *args):
        """Silencia el registro de acceso: solo interesan las alertas."""


if __name__ == "__main__":
    HTTPServer(("", PORT), AlertHandler).serve_forever()
