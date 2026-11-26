// kali-clean — Firefox preferences (re-applied at every start).

// Load chrome/userChrome.css and chrome/userContent.css.
user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);

// Built-in dark theme as the base; userChrome.css turns it near-black.
user_pref("extensions.activeThemeID", "firefox-compact-dark@mozilla.org");
user_pref("ui.systemUsesDarkTheme", 1);
user_pref("layout.css.prefers-color-scheme.content-override", 0);
user_pref("browser.theme.content-theme", 0);
user_pref("browser.theme.toolbar-theme", 0);
user_pref("devtools.theme", "dark");
user_pref("browser.uidensity", 1);

// Enable the add-ons kali-clean placed in the profile (FoxyProxy,
// Wappalyzer, Cookie-Editor) without a "was added by another program" prompt.
user_pref("extensions.autoDisableScopes", 0);
// Pick them up at startup rather than later, so they start as fresh installs
// and FoxyProxy (an MV3 add-on) gets "Access your data for all websites",
// which it needs to route traffic.
user_pref("extensions.startupScanScopes", 1);

// Let Burp see traffic to 127.0.0.1 / localhost (port-forwarded targets).
user_pref("network.proxy.allow_hijacking_localhost", true);

// Fewer interruptions.
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.aboutConfig.showWarning", false);
user_pref("browser.aboutwelcome.enabled", false);
user_pref("browser.newtabpage.activity-stream.showSponsoredTopSites", false);
user_pref("browser.newtabpage.activity-stream.showSponsored", false);
