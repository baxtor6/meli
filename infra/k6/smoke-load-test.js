// ============================================================================
// Smoke / load test ligero con k6 — ejecutado contra STAGING por el pipeline
// (ver .github/workflows/ci-cd.yml, job "frontend/backend · tests").
//
// Objetivo: detectar regresiones de performance ANTES de produccion, no
// reproducir los 10,000 req/s reales (eso es un load test dedicado aparte).
//
// Uso local:
//   k6 run -e TARGET_URL=https://staging.api.sellerdashboard.io smoke-load-test.js
// ============================================================================

import http from 'k6/http';
import { check, sleep, group } from 'k6';
import { Rate } from 'k6/metrics';

const errorRate = new Rate('errors');

const TARGET_URL = __ENV.TARGET_URL || 'https://staging.api.sellerdashboard.io';

export const options = {
  // Rampa suave: sube a 50 VUs, sostiene, y baja.
  stages: [
    { duration: '30s', target: 20 },
    { duration: '1m', target: 50 },
    { duration: '30s', target: 0 },
  ],
  // Gates: si no se cumplen, k6 sale con codigo != 0 y el pipeline falla.
  thresholds: {
    http_req_duration: ['p(95)<500', 'p(99)<1000'], // latencia
    errors: ['rate<0.01'],                           // < 1% de errores
    http_req_failed: ['rate<0.01'],
  },
};

export default function () {
  group('health', function () {
    const res = http.get(`${TARGET_URL}/actuator/health`);
    const ok = check(res, {
      'health status 200': (r) => r.status === 200,
      'health body UP': (r) => String(r.body).includes('UP'),
    });
    errorRate.add(!ok);
  });

  group('login + read endpoint', function () {
    // Login mock del challenge: obtiene un JWT por sellerId.
    const loginRes = http.post(
      `${TARGET_URL}/auth/login`,
      JSON.stringify({ sellerId: 1 }),
      { headers: { 'Content-Type': 'application/json' } }
    );
    const loginOk = check(loginRes, {
      'login status 200': (r) => r.status === 200,
    });
    errorRate.add(!loginOk);

    const token = loginOk ? loginRes.json('token') : null;
    if (token) {
      const headers = { Authorization: `Bearer ${token}` };
      // Endpoint de lectura paginado (orders) — representa el trafico comun.
      const ordersRes = http.get(`${TARGET_URL}/orders?page=0&size=20`, { headers });
      const ordersOk = check(ordersRes, {
        'orders status 200': (r) => r.status === 200,
      });
      errorRate.add(!ordersOk);
    }
  });

  sleep(1);
}
