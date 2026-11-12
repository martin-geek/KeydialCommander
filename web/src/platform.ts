// Commander serves the editor on loopback, so its browser and daemon share a host.
export const isMac = typeof navigator !== 'undefined' && /Macintosh/.test(navigator.userAgent)
export const urlOpener = isMac ? '/usr/bin/open' : 'xdg-open'
