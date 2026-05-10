import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "JL Engine — SparkByte Omni",
  description: "SparkByte Omni cinematic JL Engine deployment surface.",
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
