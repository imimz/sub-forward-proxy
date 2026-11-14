<?php
/**
 * RH Sub-Proxy configuration.
 * Copy to config.php and edit, or let install.sh generate it for you.
 */
return [
    // The ORIGINAL (foreign) subscription server base — scheme://host[:port].
    // Everything after the host is taken from the incoming request path.
    // Example: the panel that hands out https://panel1.example.com:8000/sub/<token>
    'target' => 'https://panel1.example.com:8000',

    // SOCKS5 proxy that CAN reach the target from this Iran box.
    // Leave '' to fetch directly (works if the datacenter route to the target
    // is open). Format: 'host:port'  e.g. '127.0.0.1:1080'.
    'socks5'      => '',
    'socks5_user' => '',
    'socks5_pass' => '',

    // Only these request paths are forwarded (prevents an open proxy).
    // Add your panel's sub path patterns here.
    'allow_paths' => [
        '#^/sub(/|$)#i',
        '#^/sub4me(/|$)#i',
        '#^/api/sub#i',
        '#^/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$#',  // marzban-style /<token>/<name>
    ],

    // Optional: send some paths to a different upstream instead of `target`.
    // Matching paths are allowed automatically (no need to add them to allow_paths).
    // Example: the subscription template's emergency-charge service on the panel:
    //   '#^/emergency-charge/?$#' => 'https://panel1.example.com:8765',
    'routes' => [],

    // The foreign panel often uses a self-signed cert on :8000 → keep false.
    'ssl_verify'      => false,

    'timeout'         => 25,
    'connect_timeout' => 10,

    // write upstream failures to error.log
    'log' => true,
];