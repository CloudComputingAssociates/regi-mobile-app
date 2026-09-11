# Mobile App (Flutter/Dart) RegiMenu
Sidecar App - press-to-talk (SST) and TTS, etc. and Add Food - functionality, along with Daily Menu info

# mobile phone (tethered) debugging
flutter run --dart-define-from-file=.env

# Netlify hosted mobile app
# (DEV)
https://dev--mobile-regimenu.netlify.app/

# (PROD)
https://mobile-app.regimenu.com/


# (LOCAL/VS CODE) developer workstation PWA launch
flutter run -d web-server --web-port=5000 --web-hostname=0.0.0.0 --dart-define-from-file=.env
then, open browser, http://localhost:5000   