SpotMap – In-app navigatie (zonder Apple Maps openen)

Wat zit er in deze patch:
- spotmap/NavigationManager.swift  (navigatie state + route calculatie + voice)
- spotmap/NavigationViews.swift    (UI: keuze bestemming, guidance overlay, turn-by-turn)
- spotmap/SpotMapView.swift        (integratie in bestaande map + long-press + knop)

Hoe toepassen op jouw project (Xcode):
1) Open je werkende SpotMap Xcode project.
2) Sleep NavigationManager.swift en NavigationViews.swift in je Xcode project (in de 'spotmap' group).
   - Zorg dat bij 'Add to targets' -> 'spotmap' aangevinkt staat.
3) Vervang je bestaande SpotMapView.swift door de meegeleverde versie.
   - (Tip: eerst een backup maken van je huidige SpotMapView.swift)
4) Build & Run op je device.

Gebruik:
- Long-press op de kaart -> 'Navigeer hierheen'
- Of open het menu (paperplane/route knop) en kies bestemming.
- Start/stop navigatie blijft in-app (geen Apple Maps).

Vereisten:
- Locatie permissies moeten al in Info.plist staan (NSLocationWhenInUseUsageDescription).
- Voor turn-by-turn: apparaat volume aan, mute switch uit.

Troubleshooting:
- Als je 'No such module MapKit' ziet: check target is iOS, en dat bestanden in de juiste target zitten.
- Als je geen route krijgt: check internet/Apple Directions (MKDirections) beschikbaar.
