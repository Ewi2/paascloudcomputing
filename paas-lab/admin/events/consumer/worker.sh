#!/bin/sh
# Consumidor de la cola del tenant (Fase 5). Extrae un mensaje por iteración a través de la
# API HTTP de administración de RabbitMQ, lo confirma (ACK) y simula su procesamiento.
# Al vaciarse la cola, KEDA deja pasar cooldownPeriod y reduce el Deployment a 0 réplicas.
#
# Atajo de laboratorio: la API HTTP evita construir una imagen con un cliente AMQP. El mensaje
# se confirma al extraerlo, antes de procesarlo (entrega "como máximo una vez"). Un consumidor
# de producción usa AMQP con prefetch y confirma después de procesar.
set -u

: "${RABBITMQ_API:?falta RABBITMQ_API}" "${QUEUE_NAME:?falta QUEUE_NAME}"
: "${RABBITMQ_USER:?falta RABBITMQ_USER}" "${RABBITMQ_PASS:?falta RABBITMQ_PASS}"
PROCESS_SECONDS="${PROCESS_SECONDS:-1}"   # tiempo simulado de procesamiento por mensaje
IDLE_SECONDS="${IDLE_SECONDS:-2}"         # espera cuando la cola está vacía o el broker no responde

GET_URL="$RABBITMQ_API/api/queues/%2F/$QUEUE_NAME/get"
GET_BODY='{"count":1,"ackmode":"ack_requeue_false","encoding":"auto"}'

# El proceso 1 de un contenedor ignora SIGTERM si no lo captura: sin este trap el pod
# tardaría todo el periodo de gracia en terminar cuando KEDA reduce las réplicas.
trap 'echo "Worker detenido."; exit 0' TERM INT

# Espera interrumpible: "wait" devuelve el control al llegar una señal; "sleep" a secas, no.
pause() {
  sleep "$1" &
  wait $!
}

echo "Worker iniciado. Esperando mensajes de la cola '$QUEUE_NAME'..."
while true; do
  if ! response="$(curl --silent --fail --max-time 10 \
      --user "$RABBITMQ_USER:$RABBITMQ_PASS" \
      --header 'content-type: application/json' \
      --data "$GET_BODY" "$GET_URL")"; then
    echo "El broker no respondió; se reintenta." >&2
    pause "$IDLE_SECONDS"
  elif [ "$response" = "[]" ]; then
    pause "$IDLE_SECONDS"
  else
    payload="$(printf '%s' "$response" | sed -n 's/.*"payload": *"\([^"]*\)".*/\1/p')"
    echo "Pedido procesado y confirmado (ACK): $payload"
    pause "$PROCESS_SECONDS"
  fi
done
