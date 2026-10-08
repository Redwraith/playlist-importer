# Playlist Importer

Incolla una lista `Artista - Titolo` (o importa un `.txt`), l'app trova i brani su Spotify, ti fa correggere quelli dubbi e crea la playlist **nello stesso ordine**. Per Demus passa dal link della playlist Spotify, che Demus sa importare.

## Flusso
1. Incolla o importa `.txt` → **ANALIZZA** (al primo uso: accesso a Spotify).
2. Riepilogo: trovati / da verificare / non trovati → **CONTINUA**.
3. Revisione dei brani dubbi: versione suggerita, ricerca manuale o salta.
4. **SPOTIFY** (nome playlist → CREA PLAYLIST → APRI SPOTIFY) oppure **DEMUS** (elenco da copiare o condividere).

## Matching (`ios/App/Matcher.swift`, riferimento `core/matcher.py`)
- Confronto senza maiuscole, accenti e punteggiatura; artista come parola intera (`Death` ≠ `Deathstars`).
- Preferisce artista e titolo corretti, poi la versione in studio: live, remix, acoustic, instrumental, remaster ecc. vengono scartati se non sono nel titolo richiesto.
- Se il risultato non è chiaro il brano va in **da verificare**: l'app non sceglie alla cieca.
- Duplicati: mantenuti, nella loro posizione; correggere il primo corregge anche le ripetizioni.

## Spotify
- Login PKCE (nessun client secret), refresh token solo nel Portachiavi dell'iPhone.
- Endpoint dopo le modifiche di febbraio 2026: `GET /v1/search` (max 10 risultati), `POST /v1/me/playlists`, `POST /v1/playlists/{id}/items` (100 brani per richiesta, in ordine).
- Permessi usati: `playlist-read-private` (trova le tue playlist), `playlist-modify-private` e `playlist-modify-public` (crea o aggiorna). Redirect URI: `playlist-importer://spotify-callback`. Dopo l'aggiornamento l'app chiede di nuovo l'accesso una volta, per i nuovi permessi.
- Playlist esistente: scegli una tua playlist (o scrivi un nome che hai già) e l'app aggiunge in coda solo i brani che mancano, nell'ordine della lista.
- SideStore: aggiungi la sorgente `https://github.com/Redwraith/playlist-importer/releases/download/latest/source.json` per ricevere gli aggiornamenti.
- In Development Mode l'app funziona solo per il titolare (con Premium) e fino a 5 utenti aggiunti nella dashboard Spotify.

## Demus
Non ha API. Demus però importa una playlist incollando il link di una playlist Spotify (Playlist → + → incolla), come riportano guide non ufficiali. Quindi "Importa in Demus":
1. crea o aggiorna la playlist su Spotify, nello stesso ordine;
2. la rende pubblica (Demus legge il link dall'esterno, una playlist privata non la vede);
3. copia il link e apre Demus (o la sua pagina App Store).
In alternativa resta l'elenco ordinato da copiare o condividere.

## Test
- `python3 tests/run_tests.py`: logica di matching (16 casi).
- `ios/Tests/MatcherTests.swift`: stessi casi in Swift + ordine con 10, 50 e 165 brani e duplicati. Girano in GitHub Actions.
