// Service Worker for Abiball Ticket Scanner PWA
const CACHE_NAME = 'abiball-scanner-v2';
const RUNTIME_CACHE = 'abiball-runtime-v2';

// Assets to cache on install
const STATIC_ASSETS = [
  '/',
  '/ticket_scanner.html',
  '/live_dashboard.html',
  '/include/bootstrap.min.css',
  '/include/bootstrap.bundle.min.js',
  '/include/bower_components/jquery/dist/jquery.min.js',
  '/include/bower_components/bootstrap-icons-1.13.1/bootstrap-icons.min.css',
  '/include/code.js',
  '/include/zxing.min.js',
  '/include/default.css',
  '/include/fonts.css',
  '/images/icon-192.png',
  '/images/icon-512.png'
];

// Install event - cache static assets
self.addEventListener('install', (event) => {
  console.log('[Service Worker] Install event');
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then((cache) => {
        console.log('[Service Worker] Caching static assets');
        // Don't fail if some assets are not found
        return Promise.allSettled(
          STATIC_ASSETS.map(url => 
            cache.add(url).catch(err => {
              console.warn(`[Service Worker] Failed to cache ${url}:`, err);
              return Promise.resolve();
            })
          )
        );
      })
      .then(() => self.skipWaiting())
  );
});

// Activate event - clean up old caches
self.addEventListener('activate', (event) => {
  console.log('[Service Worker] Activate event');
  event.waitUntil(
    caches.keys().then((cacheNames) => {
      return Promise.all(
        cacheNames
          .filter((cacheName) => {
            return cacheName !== CACHE_NAME && cacheName !== RUNTIME_CACHE;
          })
          .map((cacheName) => {
            console.log('[Service Worker] Deleting old cache:', cacheName);
            return caches.delete(cacheName);
          })
      );
    }).then(() => self.clients.claim())
  );
});

// Fetch event - network first, fallback to cache for API calls
// Cache first for static assets
self.addEventListener('fetch', (event) => {
  const { request } = event;
  const url = new URL(request.url);

  // Skip non-GET requests
  if (request.method !== 'GET') {
    return;
  }

  // API calls - network first, then cache
  if (url.pathname.startsWith('/api/')) {
    event.respondWith(
      fetch(request)
        .then((response) => {
          // Clone the response before caching
          const responseToCache = response.clone();
          
          // Only cache successful responses
          if (response.status === 200) {
            caches.open(RUNTIME_CACHE).then((cache) => {
              cache.put(request, responseToCache);
            });
          }
          
          return response;
        })
        .catch(() => {
          // Network failed, try cache
          return caches.match(request).then((cachedResponse) => {
            if (cachedResponse) {
              return cachedResponse;
            }
            // Return offline response for API calls
            return new Response(
              JSON.stringify({ 
                success: false, 
                error: 'Offline - keine Verbindung zum Server',
                offline: true 
              }),
              { 
                status: 503,
                headers: { 'Content-Type': 'application/json' }
              }
            );
          });
        })
    );
    return;
  }

  // HTML pages (navigation requests) - network first, fallback to cache
  // This ensures updated content is shown immediately on reload
  // Using request.destination === 'document' as primary check for reliable navigation detection
  const isNavigationRequest = request.destination === 'document' ||
    request.mode === 'navigate' || 
    (request.headers.get('accept') && request.headers.get('accept').includes('text/html') && !url.pathname.startsWith('/api/'));
  
  if (isNavigationRequest) {
    event.respondWith(
      fetch(request)
        .then((response) => {
          // Clone and cache the response for offline use
          if (response.status === 200) {
            const responseToCache = response.clone();
            caches.open(CACHE_NAME).then((cache) => {
              cache.put(request, responseToCache);
            });
          }
          return response;
        })
        .catch(() => {
          // Network failed, try cache
          return caches.match(request).then((cachedResponse) => {
            if (cachedResponse) {
              return cachedResponse;
            }
            // Return proper offline HTML page
            return new Response(
              '<!DOCTYPE html><html><head><meta charset="UTF-8"><title>Offline</title><style>body{font-family:Arial,sans-serif;display:flex;justify-content:center;align-items:center;height:100vh;margin:0;background:#1a1a2e;color:#fff;}.container{text-align:center;padding:20px;}.icon{font-size:48px;margin-bottom:20px;}h1{margin-bottom:10px;}p{color:#aaa;}</style></head><body><div class="container"><div class="icon">📡</div><h1>Offline</h1><p>Keine Verbindung zum Server. Bitte überprüfe deine Internetverbindung.</p></div></body></html>', 
              { 
                status: 503,
                statusText: 'Service Unavailable',
                headers: { 'Content-Type': 'text/html; charset=UTF-8' }
              }
            );
          });
        })
    );
    return;
  }

  // Static assets (CSS, JS, images, fonts) - cache first, then network
  event.respondWith(
    caches.match(request).then((cachedResponse) => {
      if (cachedResponse) {
        // Return cached version and update in background
        fetch(request).then((response) => {
          if (response.status === 200) {
            caches.open(CACHE_NAME).then((cache) => {
              cache.put(request, response);
            });
          }
        }).catch(() => {
          // Network error, cached version is already returned
        });
        return cachedResponse;
      }

      // Not in cache, fetch from network
      return fetch(request)
        .then((response) => {
          // Don't cache non-successful responses
          if (response.status !== 200) {
            return response;
          }

          // Clone and cache the response
          const responseToCache = response.clone();
          caches.open(CACHE_NAME).then((cache) => {
            cache.put(request, responseToCache);
          });

          return response;
        })
        .catch((error) => {
          console.error('[Service Worker] Fetch failed:', error);
          // Return a basic offline page or error
          return new Response('Offline', { 
            status: 503,
            statusText: 'Service Unavailable'
          });
        });
    })
  );
});

// Handle messages from clients
self.addEventListener('message', (event) => {
  if (event.data && event.data.type === 'SKIP_WAITING') {
    self.skipWaiting();
  }
  
  if (event.data && event.data.type === 'CACHE_URLS') {
    event.waitUntil(
      caches.open(CACHE_NAME).then((cache) => {
        return cache.addAll(event.data.urls);
      })
    );
  }
});
