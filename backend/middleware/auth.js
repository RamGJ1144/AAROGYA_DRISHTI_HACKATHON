const jwt = require("jsonwebtoken");

function authenticate(req, res, next) {
  const header = req.headers.authorization;

  if (!header) {
    return res.status(401).json({
      message: "Please login / ముందుగా Login చేయండి",
    });
  }

  try {
    const token = header.split(" ")[1];

    const decoded = jwt.verify(
      token,
      process.env.JWT_SECRET || "fallback_secret"
    );

    req.user = decoded;
    next();

  } catch {
    res.status(401).json({
      message: "Invalid token / Token తప్పు",
    });
  }
}

function adminOnly(req, res, next) {
  if (req.user.role !== "ADMIN") {
    return res.status(403).json({
      message: "Admin access only",
    });
  }

  next();
}

module.exports = { authenticate, adminOnly };