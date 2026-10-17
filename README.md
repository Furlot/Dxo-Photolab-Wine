# DxO PhotoLab 9 sous Linux (Wine)

`install-dxo-photolab.sh` installe DxO PhotoLab 9 sous Wine sur une Ubuntu vierge, avec toutes les corrections nécessaires.

> **Configuration testée** : Ubuntu 26.04 LTS, NVIDIA GeForce RTX 5070 Ti (pilote 580), Wine Staging 11.19, DxO PhotoLab 9.13.1.

## Ce qui fonctionne

| Fonction | État |
|---|---|
| Installation, démarrage, interface en français | ✅ |
| Affichage, correction et export des RAW | ✅ |
| Accélération IA sur la carte graphique (ONNX Runtime + DirectML) et OpenCL | ✅ |
| Popup de nouveautés (WebView2) | ✅ |
| Message « The current device's ICC profile is invalid » au démarrage | ⚠️ sans conséquence : cliquer sur OK (PhotoLab utilise le sRGB) |

## Prérequis

- Ubuntu 26.04 et un compte avec `sudo`.
- Une carte graphique avec un pilote Vulkan fonctionnel. Seule une carte NVIDIA avec le pilote propriétaire a été testée.
- L'installeur `DxO_PhotoLab9_Setup.exe`, téléchargé depuis le site de DxO.
- Environ 6 Go d'espace disque et une connexion Internet.

### Paquets Ubuntu

Le script les installe lui-même. Sinon, avec `--skip-system`, il faut les installer à la main :

```bash
sudo apt install -y winbind cabextract 7zip zstd unzip curl binutils python3-venv
```

| Paquet | Rôle |
|---|---|
| `winbind` | Fournit `ntlm_auth`. Sans lui, PhotoLab ne peut pas communiquer avec son moteur d'export, et l'export ne se termine jamais. |
| `cabextract` | Utilisé par winetricks (.NET, polices). |
| `7zip` | Extraction de l'installeur PhotoLab. |
| `zstd`, `unzip` | Décompression de vkd3d-proton et des polices. |
| `curl` | Téléchargements. |
| `binutils` | Commande `strings`, qui sert à lister les classes WinML. |
| `python3-venv` | Environnement Python isolé pour `fonttools` (préparation des polices). |

Le pilote NVIDIA (testé avec `nvidia-driver-580-open`) doit déjà être installé, avec ses bibliothèques Vulkan et OpenCL. Ubuntu les installe avec le pilote propriétaire.

### Wine Staging

PhotoLab a besoin de **Wine Staging 11.19**, installé depuis le dépôt officiel WineHQ. Le paquet `wine` d'Ubuntu (version 10) ne convient pas. Le script fait cette installation lui-même. Pour la faire à la main :

```bash
# retirer le Wine d'Ubuntu s'il est installé
sudo apt remove -y wine wine64

# dépôt WineHQ
sudo mkdir -pm755 /etc/apt/keyrings
sudo curl -fsSL -o /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key
sudo curl -fsSL -o /etc/apt/sources.list.d/winehq-resolute.sources \
    https://dl.winehq.org/wine-builds/ubuntu/dists/resolute/winehq-resolute.sources
sudo dpkg --add-architecture i386
sudo apt update

# Wine Staging, version fixée
sudo apt install -y --install-recommends winehq-staging=11.19~resolute-1 wine-staging=11.19~resolute-1
wine --version   # wine-11.19 (Staging)
```

`resolute` est le nom de code d'Ubuntu 26.04. Pour une autre version d'Ubuntu, le remplacer par la valeur de `VERSION_CODENAME` dans `/etc/os-release`.

Pour empêcher qu'une mise à jour change la version de Wine (facultatif) :

```bash
sudo apt-mark hold winehq-staging wine-staging
```

## Installation

Lancer le script dans un **vrai terminal**, parce que `sudo` doit pouvoir demander le mot de passe :

```bash
./install-dxo-photolab.sh --setup ~/Téléchargements/DxO_PhotoLab9_Setup.exe
```

L'installation prend 20 à 40 minutes. Des fenêtres d'installation (.NET, PhotoLab, WebView2) s'ouvrent et se ferment toutes seules : il n'y a rien à cliquer.

Une fois l'installation finie, lancer PhotoLab depuis le menu des applications (**DxO PhotoLab 9**) ou avec `~/.local/bin/dxo-photolab`.

### Options

| Option | Effet |
|---|---|
| `--setup FICHIER` | Installeur PhotoLab. Par défaut, le script le cherche dans le dossier courant, `~/Téléchargements` et `~/Downloads`. |
| `--prefix DOSSIER` | Préfixe Wine à créer (défaut : `~/.wine-dxo`). |
| `--skip-system` | Ne touche pas au système : Wine Staging et les paquets doivent déjà être installés. |
| `--no-launcher` | Ne crée ni le lanceur ni l'entrée de menu. |
| `--redo a,b,c` | Refait des étapes déjà terminées. |

Les versions peuvent être changées par variables d'environnement : `WINE_VERSION` (11.19), `VKD3D_VERSION` (3.0.1), `DXVK_VERSION` (3.1.1) et `DXO_LANG` (fr-FR).

Chaque étape terminée est marquée dans `<préfixe>/.dxo-install/`. Si le script s'arrête, il suffit de le relancer : il reprend là où il s'était arrêté.

Le journal se trouve dans `~/.cache/dxo-photolab-install/install.log`.

## Corrections appliquées

### Composants Windows

| Étape | Contenu |
|---|---|
| `prefix` | Préfixe Wine 64 bits `~/.wine-dxo`. |
| `dotnet48` | .NET Framework 4.8 (winetricks). |
| `vcrun2022` | Runtimes Visual C++ 2022 x86 et x64, téléchargés chez Microsoft. |
| `winetricks-misc` | `d3dcompiler_47`, `corefonts`, mode Windows 11, version 24H2 (build 26100) dans le registre. |
| `webview2` | Microsoft Edge WebView2 Runtime, version autonome. |
| `dxvk-vkd3d` | vkd3d-proton 3.0.1 (DirectX 12) et DXVK 3.1.1 (DirectX 9 à 11). Pour `msedgewebview2.exe`, ce sont les DLL DirectX intégrées à Wine qui restent utilisées : DXVK ne gère pas la composition utilisée par WebView2. |

### Installation de PhotoLab

| Étape | Correction |
|---|---|
| `photolab` | Le MSI est extrait de l'installeur et installé directement. Avant l'installation, les actions `CheckWindowsAppSDKRuntime` et `SetIsWebView2RuntimeRequired` sont désactivées : la première échoue sous Wine, et WebView2 est installé séparément. |

### Carte graphique et IA

| Étape | Correction |
|---|---|
| `gpu-dxcore` | Une copie modifiée du `dxcore.dll` de Wine est placée dans le dossier de PhotoLab et chargée comme DLL native. Dans cette copie, `IsAttributeSupported` répond « oui », les propriétés inconnues valent 0, et `QueryState`/`SetState` gèrent le budget de mémoire vidéo. La mémoire vidéo annoncée est réglée sur celle de la carte (`HKCU\Software\Wine\Direct3D\VideoMemorySize`, valeur lue avec `nvidia-smi`). Sans ces corrections, PhotoLab ne propose que le processeur pour l'IA, et OpenCL est indisponible. |
| `winml` | Les classes WinRT de `Microsoft.AI.MachineLearning.dll` sont déclarées dans le registre (`HKLM\SOFTWARE\Microsoft\WindowsRuntime\ActivatableClassId`). |
| `patch-bootstrap` | `Microsoft.WindowsAppRuntime.Bootstrap.dll` est modifiée pour que `MddBootstrapInitialize*` répondent « succès » (le Windows App SDK ne peut pas s'initialiser sous Wine). L'original est gardé en `.orig`. |
| `user-settings` | Dans `user.config`, `UseWindowsMLAccelerationWhenAvailable=False` et la langue `fr-FR`. Avec `patch-bootstrap`, ce réglage fait utiliser **ONNX Runtime** pour l'IA. L'autre moteur, WinML, ne peut pas charger ses modèles sous Wine, et les RAW ne s'affichent plus (erreur `0x80004001`). |

### Interface et fermeture

| Étape | Correction |
|---|---|
| `ui` | Accélération GPU de l'interface WPF désactivée (sinon les menus sont noirs). Lissage ClearType activé. La police Selawik, renommée en « Segoe UI », remplace la police d'interface de Windows. |
| `patch-codepack` | Dans `Microsoft.WindowsAPICodePack.dll`, `UnregisterApplicationRecovery` ne fait plus rien : `kernel32!UnregisterApplicationRecoveryCallback` n'existe pas dans Wine, et PhotoLab plantait à la fermeture. La modification est faite avec Mono.Cecil, à l'aide d'un SDK .NET 8 téléchargé dans le cache. L'original est gardé en `.orig`. |

### Lanceur `~/.local/bin/dxo-photolab`

| Réglage | Raison |
|---|---|
| `VK_DRIVER_FILES=…/nvidia_icd.json` | Ne laisser voir à Wine que la carte NVIDIA. Sinon, `llvmpipe` (une carte graphique logicielle) est utilisée par le moteur d'IA. |
| `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS="--no-sandbox --disable-gpu --disable-gpu-compositing"` | Le navigateur de WebView2 plante sous Wine sans ces options. |
| `fix-user-config.py` | Remet `UseWindowsMLAccelerationWhenAvailable=False` à chaque démarrage. |
| Vérification de `dxcore.dll` | Si Wine a été mis à jour, le lanceur refait la copie modifiée. Si le patch ne s'applique plus, il la supprime et affiche une notification : PhotoLab utilise alors le processeur. |

## Mises à jour

**PhotoLab :** l'installeur de la mise à jour remplace les fichiers modifiés. Il faut repasser par le script :

```bash
./install-dxo-photolab.sh --skip-system --setup ~/Téléchargements/DxO_PhotoLab9_Setup.exe \
    --redo photolab,gpu-dxcore,winml,patch-bootstrap,patch-codepack,user-settings
```

**Wine :** le lanceur s'occupe de `dxcore.dll`. Si la notification « accélération GPU désactivée » apparaît, le nouveau Wine n'est plus compatible avec `patch_dxcore.py`. Le plus simple est alors de revenir à Wine Staging 11.19 (voir `apt-mark hold` plus haut).

## Dépannage

| Symptôme | Où regarder / que faire |
|---|---|
| Erreur dans PhotoLab | `~/.wine-dxo/drive_c/users/$USER/AppData/Local/DxO/DxO PhotoLab 9/Logs/DxO.PhotoLab.txt` |
| Export bloqué | Même dossier, `DopCor.txt`. Vérifier `which ntlm_auth` (paquet `winbind`). |
| Carte graphique absente des préférences | Vérifier que `dxcore.dll` est bien dans le dossier de PhotoLab, puis `./install-dxo-photolab.sh --skip-system --redo gpu-dxcore`. |
| Processus Wine bloqués | `WINEPREFIX=~/.wine-dxo wineserver -k` |

## Désinstallation

```bash
WINEPREFIX=~/.wine-dxo wineserver -k
rm -rf ~/.wine-dxo ~/.cache/dxo-photolab-install ~/.local/share/dxo-photolab
rm -f ~/.local/bin/dxo-photolab ~/.local/share/applications/dxo-photolab.desktop
# facultatif : sudo apt remove winehq-staging wine-staging winbind
```
