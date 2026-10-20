/**
 * Frontend minimo "hola mundo". Existe solo para simular un repo real:
 * el pipeline lo compila (Vite build) y publica el estatico en S3/CloudFront.
 */
export default function App() {
  return (
    <main style={{ fontFamily: 'system-ui, sans-serif', padding: '2rem' }}>
      <h1>hola mundo desde el frontend</h1>
    </main>
  );
}
