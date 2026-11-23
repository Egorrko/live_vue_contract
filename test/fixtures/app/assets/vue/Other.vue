<script setup lang="ts">
import { useLiveEvents as events } from "live_vue_contract"
import { hook } from "./hook"

defineProps<{}>()
// same event name as nested/Card, another shape: told apart by the component that was rendered
events<{ save: { payload: { name: string } } }>(hook)
</script>

<template><div /></template>
