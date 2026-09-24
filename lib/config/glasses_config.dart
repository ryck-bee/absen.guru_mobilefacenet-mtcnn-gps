class GlassesConfig {
  static const double strictThreshold = 0.75;
  static const double looseThreshold = 0.8;

  /// Threshold kepercayaan MTCNN (R-Net & O-Net) untuk mode ketat/longgar
  static const double strictRNetThreshold = 0.6;
  static const double strictONetThreshold = 0.75;
  static const double looseRNetThreshold = 0.5;
  static const double looseONetThreshold = 0.55;
}