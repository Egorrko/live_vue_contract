<script setup lang="ts">
import Card from "./nested/Card.vue"
import { useBoard } from "./board"

defineProps<{ title: string }>()
const { refresh } = useBoard()
</script>

<template><Card label="x" @click="refresh" /></template>
