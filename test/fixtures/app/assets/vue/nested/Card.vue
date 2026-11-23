<script setup lang="ts">
import { useLiveEvents } from "live_vue_contract"
import { hook } from "../hook"

defineProps<{ label: string }>()

const live = useLiveEvents<{
  save: { payload: { id: number; label: string }; reply: { ok: boolean; error?: string } }
}>(hook)
async function save() {
  const reply = await live.pushEvent("save", { id: 1, label: "x" })
  if (!reply.ok) console.warn(reply.error)
}
</script>

<template><span @click="save">{{ label }}</span></template>
