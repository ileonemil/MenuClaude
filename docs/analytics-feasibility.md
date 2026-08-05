# Sezione analytics — fattibilità

Valutazione, non implementazione. Serve a decidere cosa vale la pena costruire.

## Il vincolo di fondo: due fonti di dati, nessuna delle due completa

**Fonte A — l'API di usage** (`api.anthropic.com/api/oauth/usage`, quella che
l'app già usa). Restituisce **solo percentuali** e date di reset, più la spesa in
crediti extra in valuta reale. Non contiene token, non contiene modelli, non
contiene storico: è una fotografia dell'istante. I campi `limit_dollars`,
`used_dollars` e `remaining_dollars` esistono nel payload ma su questo account
arrivano sempre `null` — sono per i piani a consumo, non per gli abbonamenti.

**Fonte B — i log locali di Claude Code** (`~/.claude/projects/**/*.jsonl`).
Ogni riga di risposta contiene:

```
message.model                            claude-opus-5
message.usage.input_tokens               2
message.usage.output_tokens              121
message.usage.cache_creation_input_tokens 28584
message.usage.cache_read_input_tokens    22042
timestamp                                2026-08-01T19:08:50.270Z
sessionId, cwd, version
```

Da qui si ricava tutto ciò che riguarda i token, i modelli e l'andamento nel
tempo. È la stessa fonte che usa `ccusage`.

**Il buco:** i log locali coprono **solo Claude Code su questo Mac**. L'uso da
claude.ai, dall'app desktop, da Cowork o da un altro computer non c'è. Le
percentuali della fonte A invece li includono tutti. Le due fonti quindi non
tornano: un grafico costruito sui log locali racconta una parte della storia, e
va etichettato per quello che è. Questo è il limite che condiziona ogni voce
sotto, in particolare il "subscription value".

## Voce per voce

| Cosa | Fattibile | Da dove | Complessità | Note |
| --- | --- | --- | --- | --- |
| **Trend settimanale/mensile** delle percentuali | Sì, ma va costruito | Fonte A campionata dall'app e salvata su disco | **Bassa** | Lo storico non esiste da nessuna parte: bisogna iniziare a registrarlo. Un campione ogni aggiornamento in un file locale; il grafico si popola nei giorni successivi all'attivazione, non retroattivamente. |
| **Trend di token e costo** giorno per giorno | Sì | Fonte B | **Media** | Retroattivo fin dove arrivano i log. Qui lo storico c'è già. |
| **Tabella token + costo per modello** | Sì | Fonte B + tabella prezzi | **Media** | I prezzi vanno scritti nel codice e aggiornati a mano; cache read e cache write hanno tariffe diverse dall'input normale, e sbagliarle falsa tutto. |
| **Heatmap annuale dell'attività** | Sì | Fonte B | **Bassa** | Un contatore per giorno. La griglia stile GitHub è ~150 righe di disegno. |
| **Conversione in dollari dei crediti di sessione/settimana** | **No, non davvero** | — | — | Vedi sotto. |
| **Subscription value / ROI** | Parzialmente, con un asterisco grosso | Fonte B + prezzo abbonamento | **Media** | Vedi sotto. |
| **Crediti extra spesi** (già in euro) | Sì, subito | Fonte A | **Molto bassa** | L'unico dato monetario reale che l'API fornisce. L'app già lo mostra. |
| Ripartizione per progetto/cartella | Sì | Fonte B (`cwd`) | **Bassa** | "Quale progetto mi sta bruciando la sessione". |
| Ore e giorni di punta | Sì | Fonte B | **Bassa** | Istogramma per ora del giorno. |
| Durata e costo medio per sessione | Sì | Fonte B (`sessionId`) | **Bassa** | |
| Velocità di consumo e proiezione | Sì | Fonte A campionata | **Bassa** | "A questo ritmo esaurisci la settimana giovedì": più utile di molti grafici. |

### I due punti critici

**"Conversione in dollari dei crediti di sessione e settimanali" non è
calcolabile onestamente.** L'API dà `18%`, non "18% di quanto". Il valore in
dollari di una quota di abbonamento non è un dato pubblicato: si potrebbe
*stimare* moltiplicando i token dei log locali per i prezzi API, ma sarebbe la
risposta a un'altra domanda ("quanto costerebbero questi token pagandoli a
consumo") e coprirebbe solo Claude Code. Se la sezione dicesse "hai consumato
$12,40 di sessione" sarebbe un numero inventato. Si può fare bene una cosa
diversa e dichiarata: *"i token passati da Claude Code questa settimana, a
listino API, varrebbero $X"*.

**Il "subscription value" eredita lo stesso problema.** Formula onesta:
`valore a listino API dei token da Claude Code ÷ costo mensile dell'abbonamento`.
È un limite inferiore del ROI, perché ignora l'uso via web e desktop. Va
presentato così, non come "il tuo abbonamento rende il 340%". Il prezzo
dell'abbonamento va chiesto all'utente (i piani cambiano e variano per valuta).

## Cosa comporta costruirla

- **Un archivio locale.** Oggi l'app non scrive niente oltre alle preferenze.
  Servirebbe un file (JSON compatto o SQLite) in `~/Library/Application Support/`
  con i campioni dell'API e un indice incrementale dei log. Il parsing dei JSONL
  va fatto una volta e poi solo in coda: qui sono 14 MB, ma su una macchina usata
  molto diventano centinaia — rileggerli a ogni apertura bloccherebbe l'interfaccia.
- **Una finestra vera.** Grafici, tabelle e heatmap non stanno in un popover da
  288 punti: serve una finestra separata, con la sua barra laterale o le sue tab.
- **Disegno dei grafici a mano.** Senza Xcode non ci sono Swift Charts né
  pacchetti esterni: linee, assi, barre e heatmap vanno disegnati in AppKit come
  già facciamo per le barre e gli anelli. È fattibile e viene pulito, ma è la
  voce di costo più grossa.
- **Una tabella prezzi da mantenere.** Cambia quando Anthropic cambia i listini.

## Come la spezzerei

1. **Registrare da subito i campioni dell'API.** Poche righe, nessuna interfaccia.
   Ha senso farlo *prima* di tutto il resto: ogni giorno che passa senza è
   storico perso per sempre. Se il resto non si farà mai, il costo è trascurabile.
2. **Finestra analytics con i dati dei log locali** — trend token/costo, tabella
   per modello, heatmap, ripartizione per progetto. È il grosso del valore e non
   ha ambiguità metodologiche.
3. **Proiezioni sulle percentuali** una volta che c'è qualche settimana di storico.
4. **Subscription value**, per ultimo e con l'etichetta giusta, perché è la voce
   più facile da fraintendere.

Sono tre incrementi indipendenti: si può fermarsi a qualsiasi punto.
