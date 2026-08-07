// Non-web stub. On native (phone PWA is web; native app is native) there is no
// browser, so a session is never "a desktop browser" — always false. This keeps
// tether running by default on every native client.
bool isDesktopBrowser() => false;
