import Flutter
import UIKit
import workmanager_apple

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    // The push registration refresh (lib/features/notifications/services/
    // push_refresh_job.dart): the identifier must match the Dart constant
    // and the entry in Info.plist. Registered before the app finishes
    // launching, as BGTaskScheduler requires; Dart schedules it.
    WorkmanagerPlugin.registerPeriodicTask(
      withIdentifier: "network.mostro.app.pushRefresh",
      earliestBeginInSeconds: 12 * 60 * 60
    )
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
