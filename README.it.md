<div align="center">

<img src="docs/images/icon.png" width="128" alt="MenuClaude">

# MenuClaude

**Il tuo utilizzo di Claude, sempre visibile nella barra dei menu di macOS.**

Percentuale della sessione, percentuale settimanale e countdown al prossimo reset.

<img src="docs/images/menubar.png" width="440" alt="MenuClaude nella barra dei menu">

[English](README.md) · [Scarica](../../releases/latest)

</div>

---

## Cosa mostra

Cliccando sull'icona si apre un pannello con tutte le quote del tuo piano — la
sessione da 5 ore, il limite settimanale, gli eventuali limiti per modello —
più i crediti extra a consumo e lo stato dei server Claude.

<img src="docs/images/panel-light.png" width="300" alt="Pannello, chiaro"> <img src="docs/images/panel-dark.png" width="300" alt="Pannello, scuro">

I numeri nella barra sono configurabili. In alternativa puoi mostrare **tre
anelli concentrici** in stile Apple Fitness: l'esterno è la sessione, il
centrale è l'avanzamento della finestra di cinque ore, l'interno è la settimana.
Si riempiono tutti nello stesso verso — più sono pieni, meno margine ti resta.

I colori seguono la severità indicata dall'API: verde sotto il 70%, giallo dal
70%, rosso dal 90%.

**Italiano e inglese**, si cambia dal menu.

## Requisiti

- macOS 11 Big Sur o successivo (Apple Silicon o Intel)
- [Claude Code](https://claude.com/claude-code) installato, e login fatto almeno
  una volta

Nient'altro. Nessun account da creare, nessun file di configurazione, nessuna
dipendenza.

## Installazione

### 1. Scarica e trascina

Prendi `MenuClaude.dmg` dall'[ultima release](../../releases/latest) e aprilo.
Trascina MenuClaude sulla cartella Applicazioni.

<img src="docs/images/dmg-window.png" width="480" alt="La finestra del DMG">

### 2. Primo avvio: clic destro → Apri

**Questo passaggio conta.** MenuClaude non è firmata da uno sviluppatore Apple
registrato, quindi con un doppio clic macOS si rifiuta di aprirla — a volte con
un messaggio che dice che l'app è danneggiata. Non lo è.

Apri la cartella Applicazioni, **fai clic destro su MenuClaude, scegli Apri**,
poi conferma nella finestra che compare. Va fatto una volta sola: da lì in poi
si apre normalmente.

> Perché: firmare un'app in modo che macOS si fidi al primo avvio richiede
> l'iscrizione all'Apple Developer Program (99 $/anno). Questo è uno strumento
> gratuito condiviso tra amici, quindi non è firmata. Il clic destro è il modo
> che macOS mette a disposizione per dire "so da dove viene".

### 3. Consenti l'accesso al portachiavi — scegli "Sempre"

MenuClaude legge il token OAuth che Claude Code salva nel portachiavi di login,
perché è quello che dimostra ad Anthropic di quale account riportare l'utilizzo.
macOS chiederà il permesso la prima volta.

**Scegli "Sempre", non "Consenti".** "Consenti" autorizza una singola lettura e
il pannello ricompare; "Sempre" aggiunge l'app alla lista di quelle autorizzate
e non lo rivedi più.

### 4. Consenti le notifiche (facoltativo)

Se vuoi essere avvisato quando ti avvicini ai limiti, accetta la richiesta di
notifiche. Puoi cambiare idea dopo, da **Avvisi** nel menu.

### 5. Avvio automatico (facoltativo)

Clic destro sull'icona nella barra dei menu → **Avvia al login**.

L'icona sta nella barra dei menu, in alto a destra. Non compare mai nel Dock.
**Clic sinistro** apre il pannello, **clic destro** apre le opzioni.

## Da dove arrivano i dati

Gli stessi numeri che dà `/usage` dentro Claude Code. MenuClaude legge il token
OAuth che Claude Code salva nel portachiavi (voce **Claude Code-credentials**) e
interroga direttamente `api.anthropic.com/api/oauth/usage`. Niente viene stimato
dai log locali e non c'è nessun server intermedio.

Il token resta in memoria finché è valido, quindi il portachiavi viene riletto
solo quando scade o viene rifiutato — non a ogni aggiornamento.

### Il pulsante Rinnova

Gli access token durano poche ore. Li rinnova solo la **CLI** `claude` — l'app
desktop di Claude tiene credenziali tutte sue e non tocca mai questa voce del
portachiavi. Quindi se lavori soprattutto nell'app desktop o dal web il token
invecchia in silenzio e MenuClaude smette di aggiornarsi.

Quando succede, il pannello scrive **Token scaduto** e mostra il pulsante
**Rinnova**. Usa il refresh token che è già nel tuo portachiavi, sullo stesso
endpoint e con lo stesso client id della CLI, e riscrive il risultato al suo
posto — il resto della voce, comprese le credenziali dei server MCP che Claude
Code tiene lì accanto, resta intatto.

Il rinnovo è **manuale** di proposito. Il server *ruota* il refresh token: un
rinnovo invalida il precedente, quindi se quello nuovo non riuscisse a essere
riscritto, la copia che ha Claude Code sarebbe morta. MenuClaude ritenta la
scrittura e, se fallisce comunque, te lo dice con un avviso che ti manda a
`claude auth login` invece di fallire in silenzio. Senza premere il pulsante non
succede nulla.

C'è anche `Rinnova il token` nel menu, e da Terminale:

```bash
/Applications/MenuClaude.app/Contents/MacOS/MenuClaude --renew-token
```

## Aggiornamenti

MenuClaude si aggiorna da sola. Controlla le release di GitHub all'avvio e una
volta al giorno; quando esce una versione nuova, la prima voce del menu diventa
**Aggiorna a MenuClaude x.y.z** e (se l'avviso è attivo) arriva una notifica.
C'è anche **Cerca aggiornamenti…** quando vuoi.

L'installazione scarica il DMG da questo repository, verifica che l'app dentro
corrisponda alla versione annunciata, poi si chiude, scambia il bundle e si
riapre — una decina di secondi, senza trascinare niente.

Non serve un account sviluppatore Apple: quello servirebbe a *firmare* l'app,
non a sostituirla, e `/Applications` è scrivibile dagli utenti amministratori.
Da sapere: l'aggiornamento toglie il contrassegno di quarantena alla copia
appena scaricata, ed è ciò che evita di rifare il clic destro → Apri a ogni
aggiornamento; il file arriva via HTTPS dalle release di questo stesso
repository e la sua versione viene verificata prima di sostituire qualcosa. Se
MenuClaude si trova in una cartella dove non può scrivere, lo dice e ti chiede
di spostarla in Applicazioni.

## Privacy

MenuClaude parla con due indirizzi e basta: `api.anthropic.com` per l'utilizzo e
`status.claude.com` per lo stato dei servizi. Nessuna telemetria, nessuna
analytics, nessun server intermedio, niente scritto fuori dalle preferenze
dell'app. Il token resta nel portachiavi e serve solo a firmare la richiesta ad
Anthropic.

## Opzioni

Clic destro sull'icona:

| Voce | Cosa fa |
| --- | --- |
| **Cosa mostrare** | Solo sessione, sessione + settimana, sessione + timer, tutto, solo l'anello, o i tre anelli concentrici |
| **Frequenza aggiornamento** | Da 1 a 30 minuti (default: 5) |
| **Avvisi** | Quali notifiche ricevere, e a quale soglia |
| **Lingua** | Come il sistema, Italiano o English |
| **Mostra anello** | L'indicatore circolare accanto ai numeri |
| **Icona a colori** | Disattivala per tenere l'icona monocromatica come le altre di sistema |
| **Avvia al login** | Installa un LaunchAgent in `~/Library/LaunchAgents` |
| **Cerca aggiornamenti…** | Diventa **Aggiorna a x.y.z** quando esce una release |
| **Rinnova il token** | Rinnova l'access token di Claude — vedi [sopra](#il-pulsante-rinnova) |

Il countdown scorre in locale ogni secondo. La rete viene usata solo alla
frequenza scelta, all'apertura del pannello se il dato è vecchio, e al risveglio
dal sonno.

**L'app rallenta da sola quando non succede niente.** Se due controlli
consecutivi tornano identici — di notte, o mentre sei via — l'intervallo
raddoppia, fino a mezz'ora, e torna normale appena qualcosa si muove.
L'endpoint dell'utilizzo ha un rate limit e quel budget è condiviso con Claude
Code stesso, quindi interrogarlo a vuoto conviene evitarlo.

## Avvisi

Notifiche di sistema, ognuna attivabile a sé:

| Avviso | Quando | Default |
| --- | --- | --- |
| Sessione oltre la soglia | La sessione supera la soglia scelta | acceso |
| Settimana oltre la soglia | La quota settimanale supera la soglia | acceso |
| Limite raggiunto (100%) | Una quota è esaurita | acceso |
| Crediti extra oltre la soglia | La spesa a consumo supera la soglia | spento |
| Sessione azzerata | Si apre una nuova finestra di cinque ore | spento |
| Stato dei server Claude | `status.claude.com` cambia stato — degrado o ripristino | spento |
| Errori di aggiornamento prolungati | L'app non riesce a leggere i dati da oltre 15 minuti | spento |
| Nuova versione di MenuClaude | Su GitHub è uscita una release più recente | acceso |

La soglia è una sola per tutte le quote: 50, 70, 80 (default) o 90%.

Ogni avviso scatta **al passaggio** della soglia, una volta sola: restare
all'85% non produce una notifica al minuto. La memoria si azzera quando la quota
si azzera, quindi nella finestra successiva l'avviso può riscattare.

Se le notifiche non arrivano, **Avvisi › Invia una notifica di prova** dice se il
problema è il permesso di macOS.

## Se qualcosa non va

### La barra mostra `!`

```bash
/Applications/MenuClaude.app/Contents/MacOS/MenuClaude --diagnose
```

Stampa se le credenziali sono state trovate, se il token è ancora valido e cosa
ha risposto l'API.

La causa più comune è il **token scaduto**: premi **Rinnova** nel pannello.

### "Troppe richieste all'API"

L'endpoint ha un rate limit, e il budget è condiviso con Claude Code. Quando
rifiuta, MenuClaude aspetta prima di riprovare — 2 minuti, poi 4, 8, 16, fino a
30 — e rispetta un'attesa più lunga se è il server a chiederla. Il pannello
mostra quanto manca al prossimo tentativo e intanto continua a mostrare gli
ultimi numeri buoni.

**Premere Aggiorna a ripetizione non aiuta e prima peggiorava le cose**, quindi
adesso l'app concede un solo tentativo manuale per attesa e ignora gli altri.
L'attesa sopravvive anche alla chiusura e riapertura dell'app.

### macOS dice che l'app è danneggiata

Non lo è: è il messaggio delle app non firmate. Clic destro sull'app → **Apri**.
Vedi il [passaggio 2](#2-primo-avvio-clic-destro--apri).

### Le notifiche non arrivano

```bash
/Applications/MenuClaude.app/Contents/MacOS/MenuClaude --test-notification
```

Se il permesso è stato negato, riattivalo in Impostazioni di Sistema › Notifiche
› MenuClaude.

## Compilare dai sorgenti

```bash
git clone https://github.com/ileonemil/MenuClaude.git
cd MenuClaude
./build.sh
```

Servono solo i Command Line Tools di Xcode (`xcode-select --install`), non Xcode
completo, e non c'è nessuna dipendenza esterna: è AppKit puro, compilato con
`swiftc`. Il risultato è `build/MenuClaude.app`.

Per creare l'installer:

```bash
./Tools/make-dmg.sh
```

L'autorizzazione del portachiavi è legata all'identità del codice firmato. Con
la firma ad-hoc quell'identità è l'hash del binario, quindi **ogni
ricompilazione fa ricomparire il pannello una volta**. Se ricompili spesso, crea
un certificato di firma personale — Accesso Portachiavi → Assistente
Certificato → *Crea un certificato*, tipo "Firma codice", con un nome che
contenga `MenuClaude` — e `build.sh` lo userà da solo. In alternativa
`MENUCLAUDE_SIGN_IDENTITY="nome identità"`.

## Struttura

```
Sources/MenuClaude/
  main.swift                  punto di ingresso e flag da riga di comando
  AppDelegate.swift           voce di barra, timer, menu contestuale
  PopoverViewController.swift il pannello a discesa
  Views.swift                 barre, righe e anelli disegnati a mano
  Theme.swift                 colori per severità, chiaro e scuro
  Localization.swift          stringhe italiane e inglesi
  UsageClient.swift           chiamata all'API di usage e parsing
  StatusClient.swift          stato dei server da status.claude.com
  Alerts.swift                quando notificare, e consegna
  Backoff.swift               attesa crescente dopo un 429
  Models.swift                quote, crediti, formattazione di date e durate
  Keychain.swift              lettura delle credenziali di Claude Code
  Settings.swift              preferenze in UserDefaults
  LaunchAtLogin.swift         LaunchAgent
  TokenRefresher.swift        rinnovo del token OAuth e riscrittura
  Updater.swift               aggiornamento in-app dalle release GitHub
  Diagnostics.swift           --diagnose, --renew-token, --update, --test-notification
  Preview.swift               --preview <cartella>
Tools/make-icon.sh            rigenera Resources/AppIcon.icns
Tools/make-dmg.sh             crea build/MenuClaude.dmg
docs/analytics-feasibility.md valutazione di una sezione analytics (non fatta)
build.sh                      compila e firma il bundle
```

`--preview <cartella>` disegna pannello e voce di barra su PNG, in chiaro e in
scuro, senza aprire l'app: comodo per rivedere il layout dopo una modifica.

## Note

Il payload dell'API cambia nel tempo: compaiono e spariscono quote per modello.
MenuClaude legge l'array `limits` in modo generico, così una nuova quota appare
nel pannello senza modifiche al codice; i vecchi campi `five_hour` /
`seven_day` restano come rete di sicurezza.

Il bundle identifier è `com.menuclaude.MenuClaude`. Se pubblichi una tua
versione, cambialo in `Info.plist` e in `build.sh`.

Distribuito con [licenza MIT](LICENSE). Non affiliato ad Anthropic.
