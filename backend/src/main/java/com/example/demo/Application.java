package com.example.demo;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * Backend minimo "hola mundo". Solo existe para simular un repo real:
 * expone "/" y deja que Actuator publique "/actuator/health" (lo usan
 * las probes de Kubernetes). No despliega ni hace nada mas.
 */
@SpringBootApplication
@RestController
public class Application {

    public static void main(String[] args) {
        SpringApplication.run(Application.class, args);
    }

    @GetMapping("/")
    public String hola() {
        return "hola mundo desde el backend";
    }
}
