# Vågläsare – iPhone-app

Läser av Envy-vågens display med iPhone-kameran och sparar vikterna för dosor och lock.
Avläsningen är samma som i webbversionen (version 21 = webbversion 20 + appens kamerastyrning).

Appen styr kameran fullt ut, vilket Safari inte tillåter:
- **Ställ in skärpa och ljus på displayen** – fokuserar och exponerar på displayen och låser båda
- **Lås exponeringen** och **ljusstyrka** (exponeringskompensation)
- **Lås fokus** och fokusreglage
- Zoom, ficklampa och låst färgbalans

## Bygga
Varje gång något läggs upp på `main` bygger GitHub (på en Mac i molnet) en osignerad `Vaglasare.ipa`.
Den hamnar under **Releases** (och under Actions → senaste körningen → Artifacts).

## Installera på iPhone (Windows)
1. Installera **Sideloadly** (sideloadly.io) samt **iTunes** och **iCloud** från Apples webbplats.
2. Koppla iPhonen med kabel, öppna Sideloadly och dra in `Vaglasare.ipa`.
3. Skriv in ditt Apple-ID och tryck **Start**.
4. På iPhonen: **Inställningar → Integritet och säkerhet → Utvecklarläge** → slå på (telefonen startar om).
5. **Inställningar → Allmänt → VPN och enhetshantering** → välj ditt Apple-ID → **Lita på**.

Med ett gratis Apple-ID måste appen installeras om var 7:e dag (samma steg). Vikterna ligger kvar.
