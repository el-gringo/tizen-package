# Script to package & deploy application to Tizen TV


To deploy a `./dist` folder to TV
```
tizen-package.sh deploy --host <TV_IP>
```

To deploy a single file (HTML with a redirect). This way, you won't have access to the tizen API.
```
tizen-package.sh deploy --dist tizen.html --host <TV_IP>
```