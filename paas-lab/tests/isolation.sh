#!/usr/bin/env bash
# Aislamiento entre tenants (ICMP y TCP). Requiere un CNI que aplique NetworkPolicy (Calico).
set -uo pipefail
A=tenant-alpha; B=tenant-beta; IMG=busybox:1.36
pass=0; fail=0

cleanup() {
  kubectl -n "$A" delete pod probe-a1 probe-a2 --now --ignore-not-found >/dev/null 2>&1
  kubectl -n "$B" delete pod probe-b1 --now --ignore-not-found >/dev/null 2>&1
}
trap cleanup EXIT

mk() {  # ns nombre: pod que responde HTTP en 8080
  kubectl -n "$1" run "$2" --image="$IMG" --restart=Never --command -- \
    sh -c 'echo ok > /tmp/index.html; httpd -f -p 8080 -h /tmp' >/dev/null
}
podip() { kubectl -n "$1" get pod "$2" -o jsonpath='{.status.podIP}'; }

mk "$A" probe-a1; mk "$A" probe-a2; mk "$B" probe-b1
kubectl -n "$A" wait --for=condition=Ready pod/probe-a1 pod/probe-a2 --timeout=120s >/dev/null || exit 1
kubectl -n "$B" wait --for=condition=Ready pod/probe-b1 --timeout=120s >/dev/null || exit 1
IP_A2="$(podip "$A" probe-a2)"; IP_B1="$(podip "$B" probe-b1)"

check() {  # descripción  ok|blocked  ns  pod  comando...
  local desc="$1" expect="$2" ns="$3" pod="$4"; shift 4
  kubectl -n "$ns" exec "$pod" -- "$@" >/dev/null 2>&1; local rc=$?
  if { [ "$expect" = ok ] && [ $rc -eq 0 ]; } || { [ "$expect" = blocked ] && [ $rc -ne 0 ]; }; then
    echo "PASS  $desc"; pass=$((pass+1))
  else
    echo "FAIL  $desc"; fail=$((fail+1))
  fi
}

check "alpha -> alpha  ICMP     (permitido)" ok      "$A" probe-a1 ping -c 2 -W 2 "$IP_A2"
check "alpha -> alpha  TCP 8080 (permitido)" ok      "$A" probe-a1 wget -q -T 3 -O /dev/null "http://$IP_A2:8080/"
check "alpha -> DNS del clúster (permitido)" ok      "$A" probe-a1 nslookup kubernetes.default.svc.cluster.local
check "alpha -> beta   ICMP     (bloqueado)" blocked "$A" probe-a1 ping -c 2 -W 2 "$IP_B1"
check "alpha -> beta   TCP 8080 (bloqueado)" blocked "$A" probe-a1 wget -q -T 3 -O /dev/null "http://$IP_B1:8080/"
check "beta  -> alpha  ICMP     (bloqueado)" blocked "$B" probe-b1 ping -c 2 -W 2 "$IP_A2"
check "beta  -> alpha  TCP 8080 (bloqueado)" blocked "$B" probe-b1 wget -q -T 3 -O /dev/null "http://$IP_A2:8080/"

echo "Resultado: $pass OK, $fail con falla"
[ "$fail" -eq 0 ]
