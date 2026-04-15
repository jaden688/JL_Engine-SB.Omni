"use client";
import { useEffect, useState } from "react";
import { motion, AnimatePresence } from "framer-motion";
import MainTerminal from "@/components/MainTerminal";
import ToolPane from "@/components/ToolPane";
import CodeVoid from "@/components/CodeVoid";

export default function SparkByteDemo() {
  const [phase, setPhase] = useState<"idle" | "init" | "seal" | "run" | "cascade">("idle");

  useEffect(() => {
    const runSequence = async () => {
      await new Promise(r => setTimeout(r, 1500));
      setPhase("init");
      await new Promise(r => setTimeout(r, 2000));
      setPhase("seal");
      await new Promise(r => setTimeout(r, 1800));
      setPhase("run");
      await new Promise(r => setTimeout(r, 2500));
      setPhase("cascade");
    };
    runSequence();
  }, []);

  return (
    <main className="relative min-h-screen bg-background flex items-center justify-center overflow-hidden">
      {/* Background Layers */}
      <CodeVoid />
      <div className="absolute inset-0 bg-[radial-gradient(circle_at_center,_var(--tw-gradient-stops))] from-purple-900/10 via-transparent to-transparent z-10" />
      <div className="absolute inset-0 noise-bg opacity-[0.15] z-10 pointer-events-none" />

      {/* Main Orchestration Container */}
      <div className="relative z-20 w-full max-w-4xl flex items-center justify-center scale-90 md:scale-100">
        
        <MainTerminal phase={phase} />

        <AnimatePresence>
          {phase === "cascade" && (
            <>
              <ToolPane name="gemini_cli" delay={0.2} position="top-[-100px] left-[0px]" />
              <ToolPane name="codex_engine" delay={1.4} position="top-[20px] right-[0px]" />
              <ToolPane name="claude_runtime" delay={2.6} position="bottom-[-60px] right-[40px]" />
              <ToolPane name="manus_agent" delay={3.8} position="bottom-[-120px] left-[20px]" />
              <ToolPane name="coderabbit_core" delay={5.0} position="top-[-40px] left-[-140px]" />
              <ToolPane name="vscode_bridge" delay={6.2} position="bottom-[40px] left-[-160px]" />
            </>
          )}
        </AnimatePresence>
      </div>

      {/* Final Constraint Line */}
      <AnimatePresence>
        {phase === "cascade" && (
          <motion.div
            initial={{ opacity: 0 }}
            animate={{ opacity: 0.3 }}
            transition={{ delay: 9, duration: 2 }}
            className="absolute bottom-12 font-mono text-[10px] tracking-[0.4em] text-white uppercase pointer-events-none select-none"
          >
            [ restricted reveal mode ]
          </motion.div>
        )}
      </AnimatePresence>
    </main>
  );
}
