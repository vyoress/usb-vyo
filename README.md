# USB Vyo

App macOS 13 o successivo nella barra dei menu. Mostra le unità USB fisiche esterne e la velocità negoziata con la porta: USB 2.0 (480 Mbit/s), USB 3 (5, 10 o 20 Gbit/s), oppure una velocità precedente o sconosciuta. Con più unità, la barra mostra il collegamento più lento e il numero di unità; apri il pannello per i dettagli.

La velocità è letta dal dispositivo USB padre tramite IOKit, non dalla capacità teorica dichiarata nel descrittore USB. Non misura la velocità di copia e non prova che sia stato raggiunto il massimo possibile per quel modello. Aggiornamento ogni due secondi, senza leggere o scrivere file sulla chiavetta.

## Uso

Apri `USB Vyo.app`, fai clic sull’indicatore nella barra in alto e scegli **Espelli in sicurezza**. Attendi la conferma prima di scollegare. Se l’unità è occupata l’app mostra un errore: chiudi i file e riprova. L’espulsione riguarda l’intero dispositivo, incluse tutte le sue partizioni. L’app usa il comando ufficiale `diskutil eject` di macOS, che gestisce lo smontaggio e l’espulsione dell’intera unità, incluse le unità APFS. Non usa espulsioni forzate. Il dispositivo viene ricontrollato prima dell’operazione; la conferma appare solo quando macOS comunica il successo.

Nessuna app può garantire che uno scollegamento improvviso durante una scrittura non danneggi i dati. USB Vyo non altera cache, filesystem, permessi o notifiche di macOS. La disconnessione imprevista non viene presentata come un’espulsione riuscita.

**Apri all’accesso** abilita l’avvio automatico, usando il servizio ufficiale di macOS. È disattivato inizialmente. Per rimuovere l’app, disabilita questa opzione, scegli Esci e sposta l’app nel Cestino.

Il pulsante **Ricontrolla USB** aggiorna subito l’elenco delle unità e la velocità rilevata; non cerca nuove versioni dell’app.

## Compilazione

Servono un Mac con macOS 13 o successivo e i Command Line Tools di Apple (oppure Xcode). Dalla cartella del progetto:

```sh
zsh build.sh
open "build/USB Vyo.app"
```

Per installarla, copia `build/USB Vyo.app` nella cartella Applicazioni. La build è per l’architettura del Mac su cui viene compilata; non è una build universale.

L’app è firmata localmente, non con un certificato Developer ID, e non è notarizzata. Per una distribuzione pubblica riconosciuta da Gatekeeper occorrono la firma Developer ID e la notarizzazione Apple. Questo progetto non è attualmente una versione pronta per il Mac App Store.

Lo script gestisce anche un residuo di alcuni aggiornamenti dei Command Line Tools: se trova due copie equivalenti della definizione SwiftBridging, applica una vista corretta dei file solo durante la compilazione. Non modifica i file degli strumenti Apple.

Il programma supporta `--diagnose` per una verifica in sola lettura dell’hardware rilevato e `--self-test` per controllare le etichette di velocità. Non espellono dischi.

```sh
"build/USB Vyo.app/Contents/MacOS/USBVyo" --diagnose
"build/USB Vyo.app/Contents/MacOS/USBVyo" --self-test
```

## Dati e permessi

L’app non contiene servizi di rete, telemetria o librerie di terze parti. Legge le informazioni locali dei dispositivi tramite IOKit e Disk Arbitration; l’espulsione viene eseguita da `diskutil` senza comandi di formattazione o espulsione forzata. L’opzione di avvio all’accesso usa Service Management di macOS. Non richiede i permessi di registrazione dello schermo o controllo del computer.
