# Script to package & deploy application to Tizen TV


To deploy a simple HTML to redirect to an URL

```
tizen-package.sh deploy --redirect <REDIRECT_URL> --host <TV_IP>
```

To deploy a `./dist` folder to TV
```
tizen-package.sh deploy --host <TV_IP>
```

To deploy a single file (ie: HTML with a redirect)
```
tizen-package.sh deploy --dist tizen.html --host <TV_IP>
```

This way, you won't have access to the tizen API.
