# Dashboard security tests

- open the maximum allowed concurrent connections; next connection is rejected predictably;
- hold partial headers beyond deadline; connection closes and registry releases it;
- exceed header/body caps;
- malformed content length and unsupported transfer encoding;
- call sensitive read routes without token, with wrong token, and with current token;
- verify minimal health response contains no roots, project IDs, missions, run/session IDs, settings, or event payloads;
- rotate token and verify old token fails;
- stop server with active connections and confirm all are cancelled;
- restart server and verify no stale registry entries;
- measure memory/file descriptors under repeated connection churn.
