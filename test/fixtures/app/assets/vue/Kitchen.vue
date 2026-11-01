<script setup lang="ts">
import type { Author, Comment, Settings, Size, Status, WithId } from "./types"

defineProps<{
  title: string
  count: number
  done: boolean
  note?: string
  flag?: boolean
  maybe: string | null
  status: Status
  level: 1 | 2 | 3
  size: Size
  slug: `${string}-${number}`
  tags: string[]
  pair: [string, number]
  author: Author
  editor: Author
  comments: Comment[]
  scores: Record<string, number>
  authors_by_id: Record<string, Author>
  totals: Record<"open" | "closed", number>
  index: { [key: string]: boolean }
  settings: Partial<Settings>
  picked: Pick<Settings, "theme">
  tagged: WithId<{ label: string }>
  meta: object
  anchor: HTMLElement
  when: Date
  lookup: Map<string, number>
  callback: (x: number) => void
  anything: unknown
}>()
</script>

<template><div /></template>
